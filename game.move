module rps_addr::spike_game {

    // === Aptos Framework Imports ===
    use supra_framework::coin::{Self};
    use supra_framework::account;
    use aptos_std::signer;
    use supra_framework::event::{Self, EventHandle};
    use std::option::{Self, Option};
    use std::string;
    use aptos_std::table::{Self, Table};
    use std::vector;
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::timestamp;

    // === Supra VRF Import ===
    use supra_addr::supra_vrf;
    use supra_addr::deposit;

    // === Coin Type ===
    struct LegacyCoin { }
    fun legacy_coin_type(): std::string::String { string::utf8(b"SupraCoin") }

    // === Constants ===
    const ROCK: u8 = 0;
    const PAPER: u8 = 1;
    const SCISSORS: u8 = 2;
    const DRAW: u8 = 0;
    const WIN: u8 = 1;
    const LOSE: u8 = 2;
    const NUM_CONFIRMATIONS: u64 = 3;
    const REQUIRED_RNG_COUNT: u8 = 1;
    const FEE_PERCENTAGE: u8 = 100; // 1% de fees
    const MIN_BET: u64 = 100_000_000;
    const MAX_BET: u64 = 137_000_000_000;

    // === Errors ===
    const E_INVALID_MOVE: u64 = 1;
    const E_BET_IS_ZERO: u64 = 2;
    const E_INSUFFICIENT_TREASURY_FUNDS: u64 = 3;
    const E_MODULE_NOT_INITIALIZED: u64 = 4;
    const E_NOT_MODULE_OWNER: u64 = 5;
    const E_COINSTORE_NOT_PUBLISHED: u64 = 6;
    const E_GAME_NOT_FOUND: u64 = 7;
    const E_INVALID_VRF_CALLER: u64 = 8;
    const E_UNEXPECTED_RNG_COUNT: u64 = 9;
    const E_VRF_VERIFICATION_FAILED: u64 = 10;
    const E_INVALID_FEE_PERCENTAGE: u64 = 11;
    const E_BET_TOO_LOW: u64 = 12;
    const E_BET_TOO_HIGH: u64 = 13;

    // === Resources and Structs ===
    struct TreasuryInfo has key {
        treasury_signer_cap: account::SignerCapability,
    }

    struct FeeCollector has key {
        fee_address: address,
        fee_percentage: u8,
    }

    struct PendingGame has store, copy, drop {
        player: address,
        player_move: u8,
        bet_amount_effective: u64,
        client_seed: u64,
        timestamp: u64,
    }

    struct GameLedger has key {
        pending_games: Table<u64, PendingGame>,
        completed_games: Table<u64, GameResult>,
        player_pending_nonces: Table<address, vector<u64>>,
        game_events: EventHandle<GameResult>,
    }

    struct GameResult has copy, drop, store {
        nonce: u64,
        player: address,
        player_move: u8,
        house_move: u8,
        bet_amount: u64,
        outcome: u8,
        payout_amount: u64,
        coin_type_name: std::string::String,
        season: u64,
    }

    struct SeasonManager has key {
        current_season: u64,
    }

    // === Initialization Functions ===
    fun init_module(deployer: &signer) {
        let module_addr = signer::address_of(deployer);
        assert!(module_addr == @rps_addr, E_NOT_MODULE_OWNER);
        assert!(!exists<TreasuryInfo>(module_addr), E_MODULE_NOT_INITIALIZED);
        assert!(!exists<GameLedger>(module_addr), E_MODULE_NOT_INITIALIZED);

        let (resource_signer, treasury_signer_cap) = account::create_resource_account(deployer, b"rps_treasury_seed_v2");
        move_to(deployer, TreasuryInfo { treasury_signer_cap });
        move_to(deployer, GameLedger {
            pending_games: table::new<u64, PendingGame>(),
            completed_games: table::new<u64, GameResult>(),
            player_pending_nonces: table::new<address, vector<u64>>(),
            game_events: account::new_event_handle<GameResult>(deployer),
        });

        let treasury_signer_ref = &resource_signer;
        if (!coin::is_account_registered<SupraCoin>(signer::address_of(treasury_signer_ref))) {
            coin::register<SupraCoin>(treasury_signer_ref);
        };

        move_to(deployer, FeeCollector {
            fee_address: module_addr,
            fee_percentage: 100
        });

        move_to(deployer, SeasonManager { current_season: 0 });
    }

    fun get_current_season(): u64 {
        let current_time = timestamp::now_seconds();
        let start_time = 1743379200u64;
        let seconds_per_month = 2592000u64;
        let months_since_start = (current_time - start_time) / seconds_per_month;
        months_since_start
    }

    // === Administrative Functions ===
    public entry fun set_fee_address(owner: &signer, new_fee_address: address) acquires FeeCollector {
        assert!(signer::address_of(owner) == @rps_addr, E_NOT_MODULE_OWNER);
        let fee_collector = borrow_global_mut<FeeCollector>(@rps_addr);
        fee_collector.fee_address = new_fee_address;
    }

    // === Game Flow ===
    public entry fun start_game(player: &signer, player_move: u8, bet_amount: u64)
    acquires TreasuryInfo, GameLedger, FeeCollector {
        assert!(player_move == ROCK || player_move == PAPER || player_move == SCISSORS, E_INVALID_MOVE);
        assert!(bet_amount >= MIN_BET, E_BET_TOO_LOW);
        assert!(bet_amount <= MAX_BET, E_BET_TOO_HIGH);
        assert!(bet_amount > 0, E_BET_IS_ZERO);

        let module_addr = @rps_addr;
        assert!(exists<TreasuryInfo>(module_addr), E_MODULE_NOT_INITIALIZED);
        assert!(exists<GameLedger>(module_addr), E_MODULE_NOT_INITIALIZED);
        assert!(exists<FeeCollector>(module_addr), E_MODULE_NOT_INITIALIZED);

        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        let treasury_addr = signer::address_of(&treasury_signer);

        let fee_collector = borrow_global<FeeCollector>(module_addr);
        let fee_address = fee_collector.fee_address;

        let fee_percentage = fee_collector.fee_percentage;
        let fee_amount = (bet_amount * (fee_percentage as u64)) / 10000;
        let bet_amount_effective = bet_amount - fee_amount;

        let required_balance = bet_amount_effective * 2; 
        assert!(coin::balance<SupraCoin>(treasury_addr) >= required_balance, E_INSUFFICIENT_TREASURY_FUNDS);

        let bet_coin = coin::withdraw<SupraCoin>(player, bet_amount_effective);
        coin::deposit(treasury_addr, bet_coin);

        let fee_coin = coin::withdraw<SupraCoin>(player, fee_amount);
        coin::deposit(fee_address, fee_coin);

        let callback_address = module_addr;
        let callback_module = string::utf8(b"spike_game");
        let callback_function = string::utf8(b"fulfill_randomness");
        let client_seed = 0u64;

        let nonce = supra_vrf::rng_request(
            &treasury_signer,
            callback_address,
            callback_module,
            callback_function,
            REQUIRED_RNG_COUNT,
            client_seed,
            NUM_CONFIRMATIONS
        );

        let game_ledger = borrow_global_mut<GameLedger>(module_addr);
        let pending_game = PendingGame {
            player: signer::address_of(player),
            player_move: player_move,
            bet_amount_effective: bet_amount_effective,
            client_seed: client_seed,
            timestamp: timestamp::now_seconds(),
        };
        table::add(&mut game_ledger.pending_games, nonce, pending_game);

        let player_addr = signer::address_of(player);
        if (!table::contains(&game_ledger.player_pending_nonces, player_addr)) {
            table::add(&mut game_ledger.player_pending_nonces, player_addr, vector::empty<u64>());
        };
        let player_nonces = table::borrow_mut(&mut game_ledger.player_pending_nonces, player_addr);
        vector::push_back(player_nonces, nonce);

    }

    // === Helper Functions ===
    fun determine_outcome(player_move: u8, house_move: u8): u8 {
        if (player_move == house_move) {
            DRAW
        } else if ((player_move == ROCK && house_move == SCISSORS) ||
                   (player_move == PAPER && house_move == ROCK) ||
                   (player_move == SCISSORS && house_move == PAPER)) {
            WIN
        } else {
            LOSE
        }
    }

    public entry fun fulfill_randomness(
        nonce: u64,
        message: vector<u8>,
        signature: vector<u8>,
        caller_address: address,
        rng_count: u8,
        client_seed: u64,
    ) acquires TreasuryInfo, GameLedger {
        let verified_result: vector<u256> = supra_vrf::verify_callback(
            nonce, message, signature, caller_address, rng_count, client_seed
        );
        assert!(vector::length(&verified_result) == (REQUIRED_RNG_COUNT as u64), E_UNEXPECTED_RNG_COUNT);

        let random_value_u256 = *vector::borrow(&verified_result, 0);
        let house_move = ((random_value_u256 % 3u256) as u8);

        let module_addr = @rps_addr;
        assert!(exists<GameLedger>(module_addr), E_MODULE_NOT_INITIALIZED);
        let game_ledger = borrow_global_mut<GameLedger>(module_addr);
        assert!(table::contains(&game_ledger.pending_games, nonce), E_GAME_NOT_FOUND);

        let pending_game = table::remove(&mut game_ledger.pending_games, nonce);
        assert!(pending_game.client_seed == client_seed, E_VRF_VERIFICATION_FAILED);
        let outcome = determine_outcome(pending_game.player_move, house_move);

        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        let treasury_addr = signer::address_of(&treasury_signer);

        let payout_amount = if (outcome == WIN) {
            let total_payout = pending_game.bet_amount_effective * 2;
            assert!(coin::balance<SupraCoin>(treasury_addr) >= total_payout, E_INSUFFICIENT_TREASURY_FUNDS);
            let payout_coin = coin::withdraw<SupraCoin>(&treasury_signer, total_payout);
            coin::deposit(pending_game.player, payout_coin);
            pending_game.bet_amount_effective
        } else if (outcome == DRAW) {
            assert!(coin::balance<SupraCoin>(treasury_addr) >= pending_game.bet_amount_effective, E_INSUFFICIENT_TREASURY_FUNDS);
            let refund_coin = coin::withdraw<SupraCoin>(&treasury_signer, pending_game.bet_amount_effective);
            coin::deposit(pending_game.player, refund_coin);
            0
        } else {
            0
        };

        let current_season = get_current_season();
        let game_result = GameResult {
            nonce: nonce,
            player: pending_game.player,
            player_move: pending_game.player_move,
            house_move: house_move,
            bet_amount: pending_game.bet_amount_effective,
            outcome: outcome,
            payout_amount: payout_amount,
            coin_type_name: legacy_coin_type(),
            season: current_season,
        };
        table::add(&mut game_ledger.completed_games, nonce, game_result);

        event::emit_event<GameResult>(
            &mut game_ledger.game_events,
            game_result
        );


        let player_addr = pending_game.player;
        if (table::contains(&game_ledger.player_pending_nonces, player_addr)) {
            let player_nonces = table::borrow_mut(&mut game_ledger.player_pending_nonces, player_addr);
            let (found, index) = vector::index_of(player_nonces, &nonce);
            if (found) {
                vector::remove(player_nonces, index);
                if (vector::is_empty(player_nonces)) {
                    table::remove(&mut game_ledger.player_pending_nonces, player_addr);
                };
            };
        };
    }

    public entry fun claim_refunds(player: &signer) acquires GameLedger, TreasuryInfo {
        let module_addr = @rps_addr;
        let game_ledger = borrow_global_mut<GameLedger>(module_addr);
        let player_addr = signer::address_of(player);

        // Si el jugador no tiene nonces pendientes, salir
        if (!table::contains(&game_ledger.player_pending_nonces, player_addr)) {
            return
        };
        let player_nonces = table::borrow_mut(&mut game_ledger.player_pending_nonces, player_addr);

        let current_time = timestamp::now_seconds();
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);

        let nonces_to_remove = vector::empty<u64>();
        let i = 0;
        while (i < vector::length(player_nonces)) {
            let nonce = *vector::borrow(player_nonces, i);
            if (table::contains(&game_ledger.pending_games, nonce)) {
                let pending_game = table::borrow(&game_ledger.pending_games, nonce);
                if (current_time - pending_game.timestamp > 3600) {
                    let refund_amount = pending_game.bet_amount_effective;
                    let refund_coin = coin::withdraw<SupraCoin>(&treasury_signer, refund_amount);
                    coin::deposit(player_addr, refund_coin);
                    vector::push_back(&mut nonces_to_remove, nonce);
                };
            };
            i = i + 1;
        };
        for (i in 0..vector::length(&nonces_to_remove)) {
            let nonce = *vector::borrow(&nonces_to_remove, i);
            table::remove(&mut game_ledger.pending_games, nonce);
            let (_, index) = vector::index_of(player_nonces, &nonce);
            vector::remove(player_nonces, index);
        };
    }

    // === Administrative Functions ===
    public entry fun fund_treasury(owner: &signer, amount: u64) acquires TreasuryInfo {
        assert!(signer::address_of(owner) == @rps_addr, E_NOT_MODULE_OWNER);
        let module_addr = @rps_addr;
        assert!(exists<TreasuryInfo>(module_addr), E_MODULE_NOT_INITIALIZED);
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        let treasury_addr = signer::address_of(&treasury_signer);
        assert!(coin::is_account_registered<SupraCoin>(treasury_addr), E_COINSTORE_NOT_PUBLISHED);
        let coins_to_deposit = coin::withdraw<SupraCoin>(owner, amount);
        coin::deposit(treasury_addr, coins_to_deposit);
    }

    public entry fun withdraw_from_treasury(owner: &signer, amount: u64) acquires TreasuryInfo {
        assert!(signer::address_of(owner) == @rps_addr, E_NOT_MODULE_OWNER);
        let module_addr = @rps_addr;
        assert!(exists<TreasuryInfo>(module_addr), E_MODULE_NOT_INITIALIZED);
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        let treasury_addr = signer::address_of(&treasury_signer);
        assert!(coin::balance<SupraCoin>(treasury_addr) >= amount, E_INSUFFICIENT_TREASURY_FUNDS);
        let coins_to_withdraw = coin::withdraw<SupraCoin>(&treasury_signer, amount);
        coin::deposit(signer::address_of(owner), coins_to_withdraw);
    }

    public entry fun deposit_supra_to_vrf(
        user: &signer,
        amount: u64
    ) acquires TreasuryInfo {
        assert!(signer::address_of(user) == @rps_addr, E_NOT_MODULE_OWNER);
        let module_addr = @rps_addr;
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        let treasury_addr = signer::address_of(&treasury_signer);
        if (!coin::is_account_registered<SupraCoin>(treasury_addr)) {
            coin::register<SupraCoin>(&treasury_signer);
        };
        let coins_to_deposit = coin::withdraw<SupraCoin>(user, amount);
        coin::deposit(treasury_addr, coins_to_deposit);

        deposit::deposit_fund(&treasury_signer, amount);
    }

    public entry fun withdraw_supra_to_vrf(
        user: &signer,
        amount: u64
    ) acquires TreasuryInfo {
        assert!(signer::address_of(user) == @rps_addr, E_NOT_MODULE_OWNER);
        let module_addr = @rps_addr;
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        let treasury_addr = signer::address_of(&treasury_signer);

        let coins_to_withdraw = coin::withdraw<SupraCoin>(user, amount);
        coin::deposit(treasury_addr, coins_to_withdraw);

        deposit::withdraw_fund(&treasury_signer, amount);
    }

    public entry fun add_contract_to_vrf_whitelist(
        user: &signer,      
        caller_address: address
    ) acquires TreasuryInfo {
        assert!(signer::address_of(user) == @rps_addr, E_NOT_MODULE_OWNER);
        let module_addr = @rps_addr;
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);

        deposit::add_contract_to_whitelist(&treasury_signer, caller_address);
    }

    public entry fun remove_contract_from_vrf_whitelist(
        user: &signer,      
        caller_address: address
    ) acquires TreasuryInfo {
        assert!(signer::address_of(user) == @rps_addr, E_NOT_MODULE_OWNER);
        let module_addr = @rps_addr;
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);

        deposit::remove_contract_from_whitelist(&treasury_signer, caller_address);
    }
    
    // === View Functions ===
    #[view]
    public fun get_treasury_balance(): u64 acquires TreasuryInfo {
        let module_addr = @rps_addr;
        assert!(exists<TreasuryInfo>(module_addr), E_MODULE_NOT_INITIALIZED);
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_addr = account::get_signer_capability_address(&treasury_info.treasury_signer_cap);
        if (coin::is_account_registered<SupraCoin>(treasury_addr)) {
            coin::balance<SupraCoin>(treasury_addr)
        } else {
            0
        }
    }

    #[view]
    public fun get_pending_game(nonce: u64): Option<PendingGame> acquires GameLedger {
        let module_addr = @rps_addr;
        assert!(exists<GameLedger>(module_addr), E_MODULE_NOT_INITIALIZED);
        let game_ledger = borrow_global<GameLedger>(module_addr);
        if (table::contains(&game_ledger.pending_games, nonce)) {
            option::some(*table::borrow(&game_ledger.pending_games, nonce))
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_fee_percentage(): u8 acquires FeeCollector {
        let fee_collector = borrow_global<FeeCollector>(@rps_addr);
        fee_collector.fee_percentage
    }

    #[view]
    public fun get_treasury_address(): address acquires TreasuryInfo {
        let module_addr = @rps_addr;
        assert!(exists<TreasuryInfo>(module_addr), E_MODULE_NOT_INITIALIZED);
        let treasury_info = borrow_global<TreasuryInfo>(module_addr);
        let treasury_signer = account::create_signer_with_capability(&treasury_info.treasury_signer_cap);
        signer::address_of(&treasury_signer)
    }
    #[view]
    public fun get_last_pending_nonce(player_addr: address): Option<u64> acquires GameLedger {
        let module_addr = @rps_addr;
        assert!(exists<GameLedger>(module_addr), E_MODULE_NOT_INITIALIZED);
        let game_ledger = borrow_global<GameLedger>(module_addr);
        if (table::contains(&game_ledger.player_pending_nonces, player_addr)) {
            let player_nonces = table::borrow(&game_ledger.player_pending_nonces, player_addr);
            if (!vector::is_empty(player_nonces)) {
                let last_nonce = *vector::borrow(player_nonces, vector::length(player_nonces) - 1);
                option::some(last_nonce)
            } else {
                option::none()
            }
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_game_result(nonce: u64): Option<GameResult> acquires GameLedger {
        let module_addr = @rps_addr;
        assert!(exists<GameLedger>(module_addr), E_MODULE_NOT_INITIALIZED);
        let game_ledger = borrow_global<GameLedger>(module_addr);
        if (table::contains(&game_ledger.completed_games, nonce)) {
            option::some(*table::borrow(&game_ledger.completed_games, nonce))
        } else {
            option::none()
        }
    }
}
