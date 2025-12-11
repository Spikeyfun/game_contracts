module roulette_addr::supra_raffle {
    use std::string::{String};
    use std::vector;
    use std::signer;
    use std::option::{Self, Option};
    use std::error;
    
    use supra_framework::coin::{Self};
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::object::{Self, Object};
    use supra_framework::fungible_asset::{Metadata, FungibleStore, FungibleAsset};
    use supra_framework::dispatchable_fungible_asset;
    use supra_framework::primary_fungible_store;
    use supra_framework::event::{Self, EventHandle};
    use supra_framework::timestamp; 
    
    use aptos_std::table::{Self, Table};
    use aptos_token::token::{Self, TokenId};    
    use aptos_token_objects::token as token_v2; 

    use supra_addr::supra_vrf;
    use supra_addr::deposit::{Self, SupraVRFPermit};
    use game_addr::vrf_manager; 

    // ==================================================================================
    //                                   CONSTANTS
    // ==================================================================================

    const E_NOT_ADMIN: u64 = 1;
    const E_GAME_NOT_FOUND: u64 = 4;
    const E_PERMIT_MISSING: u64 = 7;
    const E_NO_PARTICIPANTS: u64 = 8;
    const E_TOO_EARLY_TO_REFUND: u64 = 9;
    const E_NOT_CREATOR: u64 = 10;
    const E_INVALID_AMOUNT: u64 = 11;

    const ASSET_TYPE_FA: u8 = 1;      
    const ASSET_TYPE_NFT_V1: u8 = 2;  
    const ASSET_TYPE_NFT_V2: u8 = 3;  
    const REFUND_DELAY_SECONDS: u64 = 86400; 

    // ==================================================================================
    //                                   STRUCTS
    // ==================================================================================

    struct RaffleClient has store {}

    struct RaffleAsset has store, drop, copy {
        asset_type: u8,
        amount: u64,      
        object_address: Option<address>,  
        v1_token_id: Option<TokenId>,     
    }

    struct PendingRaffle has store, drop {
        creator: address,
        participants: vector<address>, 
        prize: RaffleAsset,            
        creation_time: u64             
    }

    struct RaffleResult has store, drop, copy {
        nonce: u64,
        creator: address,
        winner: address,
        prize_amount: u64,
        asset_type: u8,
        completed_at: u64,
        random_number: u256
    }

    struct RaffleState has key {
        treasury_cap: SignerCapability,
        vrf_permit: Option<SupraVRFPermit<RaffleClient>>, 
        pending_raffles: Table<u64, PendingRaffle>,         
        completed_raffles: Table<u64, RaffleResult>, 
        creator_nonces: Table<address, vector<u64>>,

        raffle_created_events: EventHandle<RaffleCreatedEvent>,
        raffle_completed_events: EventHandle<RaffleCompletedEvent>,
    }

    struct RaffleConfig has key {
        admin: address,
        fee_recipient: address,
        creation_fee: u64, 
    }

    // View unificada
    struct RaffleStatusView has drop, copy, store {
        status: u8,
        creator: address,
        winner: Option<address>,
        prize_amount: u64,
        asset_type: u8,
        participants_count: u64,
        nonce: u64,
        random_number: Option<u256>
    }

    struct RaffleCreatedEvent has drop, store { 
        nonce: u64,
        creator: address,
        count: u64
    }

    struct RaffleCompletedEvent has drop, store { 
        nonce: u64, 
        winner: address, 
        amount: u64,
        random_number: u256
    }
    // ==================================================================================
    //                                INITIALIZATION
    // ==================================================================================

    fun init_module(deployer: &signer) {
        let (resource_signer, resource_cap) = account::create_resource_account(deployer, b"raffle_treasury_v2_final");        
        let permit = deposit::init_vrf_module<RaffleClient>(deployer);

        move_to(deployer, RaffleState {
            treasury_cap: resource_cap,
            vrf_permit: option::some(permit), 
            pending_raffles: table::new(),
            completed_raffles: table::new(),
            creator_nonces: table::new(),
            raffle_created_events: account::new_event_handle<RaffleCreatedEvent>(deployer),
            raffle_completed_events: account::new_event_handle<RaffleCompletedEvent>(deployer),
        });

        if (!coin::is_account_registered<SupraCoin>(signer::address_of(&resource_signer))) {
            coin::register<SupraCoin>(&resource_signer);
        };
        token::initialize_token_store(&resource_signer);
        token::opt_in_direct_transfer(&resource_signer, true);

        move_to(deployer, RaffleConfig {
            admin: signer::address_of(deployer),
            fee_recipient: signer::address_of(deployer),
            creation_fee: 100_000_000, // 1 SUPRA de fee por defecto
        });
    }

    fun internal_withdraw(
        signer: &signer,
        store: Object<FungibleStore>,
        amount: u64
    ): FungibleAsset {
        dispatchable_fungible_asset::withdraw(signer, store, amount)
    }

    fun internal_deposit(
        store: Object<FungibleStore>,
        asset: FungibleAsset
    ) {
        dispatchable_fungible_asset::deposit(store, asset)
    }

    // ==================================================================================
    //                           1. CREATE RAFFLE (Entry Points)
    // ==================================================================================

    public entry fun create_coin_raffle<CoinType>(
        creator: &signer, 
        participants: vector<address>, 
        amount: u64
    ) acquires RaffleState, RaffleConfig {
        assert!(amount > 0, error::invalid_argument(E_INVALID_AMOUNT));
        let coins = coin::withdraw<CoinType>(creator, amount);
        let metadata = option::extract(&mut coin::paired_metadata<CoinType>());
        let asset_addr = object::object_address(&metadata);
        let state = borrow_global_mut<RaffleState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        primary_fungible_store::deposit(signer::address_of(&resource_signer), coin::coin_to_fungible_asset(coins));
        execute_raffle(creator, participants, RaffleAsset { asset_type: ASSET_TYPE_FA, amount, object_address: option::some(asset_addr), v1_token_id: option::none() }, state);
    }

    public entry fun create_fa_raffle(
        creator: &signer, 
        participants: vector<address>, 
        asset_address: address, 
        amount: u64
    ) acquires RaffleState, RaffleConfig {
        let state = borrow_global_mut<RaffleState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let asset_obj = object::address_to_object<Metadata>(asset_address);
        let creator_addr = signer::address_of(creator);
        let creator_store = primary_fungible_store::primary_store(creator_addr, asset_obj);
        let assets = internal_withdraw(creator, creator_store, amount);

        let treasury_addr = signer::address_of(&resource_signer);
        let treasury_store = primary_fungible_store::ensure_primary_store_exists(treasury_addr, asset_obj);
        internal_deposit(treasury_store, assets);
        execute_raffle(creator, participants, RaffleAsset { asset_type: ASSET_TYPE_FA, amount, object_address: option::some(asset_address), v1_token_id: option::none() }, state);
    }

    public entry fun create_nft_v1_raffle(
        creator: &signer, 
        participants: vector<address>, 
        creator_addr: address, 
        collection: String, 
        name: String, 
        prop_ver: u64
    ) acquires RaffleState, RaffleConfig {
        let state = borrow_global_mut<RaffleState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let token_id = token::create_token_id_raw(creator_addr, collection, name, prop_ver);
        token::transfer(creator, token_id, signer::address_of(&resource_signer), 1);
        execute_raffle(creator, participants, RaffleAsset { asset_type: ASSET_TYPE_NFT_V1, amount: 1, object_address: option::none(), v1_token_id: option::some(token_id) }, state);
    }

    public entry fun create_nft_v2_raffle(
        creator: &signer, 
        participants: vector<address>, 
        object_address: address
    ) acquires RaffleState, RaffleConfig {
        let state = borrow_global_mut<RaffleState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let obj = object::address_to_object<token_v2::Token>(object_address);
        object::transfer(creator, obj, signer::address_of(&resource_signer));
        execute_raffle(creator, participants, RaffleAsset { asset_type: ASSET_TYPE_NFT_V2, amount: 1, object_address: option::some(object_address), v1_token_id: option::none() }, state);
    }

    fun execute_raffle(
        creator: &signer, 
        participants: vector<address>, 
        prize: RaffleAsset, 
        state: &mut RaffleState
    ) acquires RaffleConfig {
        let creator_addr = signer::address_of(creator);
        assert!(option::is_some(&state.vrf_permit), error::invalid_state(E_PERMIT_MISSING));
        let count_len = vector::length(&participants);
        assert!(count_len > 0, error::invalid_argument(E_NO_PARTICIPANTS));

        let config = borrow_global<RaffleConfig>(@roulette_addr);
        if (config.creation_fee > 0) {
            // Cobra el fee en SupraCoin
            let fee = coin::withdraw<SupraCoin>(creator, config.creation_fee);
            coin::deposit(config.fee_recipient, fee);
        };
        
        let resource_addr = account::get_signer_capability_address(&state.treasury_cap);
        let (rng, conf, seed) = vrf_manager::authorize_and_get_config(resource_addr);

        let permit = option::borrow(&state.vrf_permit);
        let nonce = supra_vrf::rng_request_v2<RaffleClient>(permit, std::string::utf8(b"fulfill_randomness"), rng, seed, conf);

        table::add(&mut state.pending_raffles, nonce, PendingRaffle {
            creator: creator_addr,
            participants, 
            prize,
            creation_time: timestamp::now_seconds()
        });

        if (!table::contains(&state.creator_nonces, creator_addr)) {
            table::add(&mut state.creator_nonces, creator_addr, vector::empty());
        };
        vector::push_back(table::borrow_mut(&mut state.creator_nonces, creator_addr), nonce);
        // -----------------------------------------------------------
        
        event::emit_event(&mut state.raffle_created_events, RaffleCreatedEvent { 
            nonce, creator: creator_addr, count: count_len 
        });
    }

    // ==================================================================================
    //                           2. CALLBACK
    // ==================================================================================

    public entry fun fulfill_randomness(
        nonce: u64,
        message: vector<u8>, 
        signature: vector<u8>, 
        caller_address: address, 
        rng_count: u8, 
        client_seed: u64,
    ) acquires RaffleState {
        let verified = vrf_manager::verify_supra_callback(nonce, message, signature, caller_address, rng_count, client_seed);
        let random_val = *vector::borrow(&verified, 0);

        let state = borrow_global_mut<RaffleState>(@roulette_addr);

        if (!table::contains(&state.pending_raffles, nonce)) { return };
        let raffle = table::remove(&mut state.pending_raffles, nonce);
        let participants_len = vector::length(&raffle.participants);
        if (participants_len == 0) { return };

        let winner_index = ((random_val % (participants_len as u256)) as u64);
        let winner_addr = *vector::borrow(&raffle.participants, winner_index);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);

        if (raffle.prize.asset_type == ASSET_TYPE_FA) {
            let asset_addr = *option::borrow(&raffle.prize.object_address);
            let asset_obj = object::address_to_object<Metadata>(asset_addr);
            
            let resource_addr = signer::address_of(&resource_signer);
            let treasury_store = primary_fungible_store::primary_store(resource_addr, asset_obj);
            let assets = internal_withdraw(&resource_signer, treasury_store, raffle.prize.amount);
            
            let winner_store = primary_fungible_store::ensure_primary_store_exists(winner_addr, asset_obj);
            internal_deposit(winner_store, assets);

        } else if (raffle.prize.asset_type == ASSET_TYPE_NFT_V2) {
            let obj_addr = *option::borrow(&raffle.prize.object_address);
            let obj = object::address_to_object<token_v2::Token>(obj_addr);
            object::transfer(&resource_signer, obj, winner_addr);
        } else if (raffle.prize.asset_type == ASSET_TYPE_NFT_V1) {
            let token_id = *option::borrow(&raffle.prize.v1_token_id);
            token::transfer(&resource_signer, token_id, winner_addr, 1);
        };

        let result = RaffleResult {
            nonce,
            creator: raffle.creator,
            winner: winner_addr,
            prize_amount: raffle.prize.amount,
            asset_type: raffle.prize.asset_type,
            completed_at: timestamp::now_seconds(),
            random_number: random_val
        };
        table::add(&mut state.completed_raffles, nonce, result);

        event::emit_event(&mut state.raffle_completed_events, RaffleCompletedEvent {
            nonce, 
            winner: winner_addr, 
            amount: raffle.prize.amount,
            random_number: random_val
        });
    }


    public entry fun recover_stuck_asset(
        creator: &signer, 
        nonce: u64
        ) acquires RaffleState {
        let creator_addr = signer::address_of(creator);
        let state = borrow_global_mut<RaffleState>(@roulette_addr);
        assert!(table::contains(&state.pending_raffles, nonce), error::not_found(E_GAME_NOT_FOUND));
        let raffle_ref = table::borrow(&state.pending_raffles, nonce);
        assert!(raffle_ref.creator == creator_addr, error::permission_denied(E_NOT_CREATOR));
        let now = timestamp::now_seconds();
        assert!(now > raffle_ref.creation_time + REFUND_DELAY_SECONDS, error::invalid_state(E_TOO_EARLY_TO_REFUND));
        let raffle = table::remove(&mut state.pending_raffles, nonce);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        if (raffle.prize.asset_type == ASSET_TYPE_FA) {
            let asset_addr = *option::borrow(&raffle.prize.object_address);
            let asset_obj = object::address_to_object<Metadata>(asset_addr);
            let resource_addr = signer::address_of(&resource_signer);

            let treasury_store = primary_fungible_store::primary_store(resource_addr, asset_obj);
            let assets = internal_withdraw(&resource_signer, treasury_store, raffle.prize.amount);

            let creator_store = primary_fungible_store::ensure_primary_store_exists(creator_addr, asset_obj);
            internal_deposit(creator_store, assets);        } else if (raffle.prize.asset_type == ASSET_TYPE_NFT_V2) {
            let obj_addr = *option::borrow(&raffle.prize.object_address);
            let obj = object::address_to_object<token_v2::Token>(obj_addr);
            object::transfer(&resource_signer, obj, creator_addr);
        } else if (raffle.prize.asset_type == ASSET_TYPE_NFT_V1) {
            let token_id = *option::borrow(&raffle.prize.v1_token_id);
            token::transfer(&resource_signer, token_id, creator_addr, 1);
        };
    }

    //Admin Functions

    public entry fun set_raffle_config(
        admin: &signer, 
        new_fee: u64, 
        new_recipient: address
    ) acquires RaffleConfig {
        let config = borrow_global_mut<RaffleConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        config.creation_fee = new_fee;
        config.fee_recipient = new_recipient;
    }

    // ==================================================================================
    //                           4. VIEWS (Frontend Queries)
    // ==================================================================================
    
    #[view]
    public fun get_last_pending_nonce(creator_addr: address): Option<u64> acquires RaffleState {
        let state = borrow_global<RaffleState>(@roulette_addr);
        if (table::contains(&state.creator_nonces, creator_addr)) {
            let nonces = table::borrow(&state.creator_nonces, creator_addr);
            if (!vector::is_empty(nonces)) {
                let last_nonce = *vector::borrow(nonces, vector::length(nonces) - 1);
                option::some(last_nonce)
            } else {
                option::none()
            }
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_raffle_status(nonce: u64): RaffleStatusView acquires RaffleState {
        let state = borrow_global<RaffleState>(@roulette_addr);
        
        if (table::contains(&state.pending_raffles, nonce)) {
            let r = table::borrow(&state.pending_raffles, nonce);
            return RaffleStatusView {
                status: 1, 
                creator: r.creator,
                winner: option::none(),
                prize_amount: r.prize.amount,
                asset_type: r.prize.asset_type,
                participants_count: vector::length(&r.participants),
                nonce,
                random_number: option::none()
            }
        };

        if (table::contains(&state.completed_raffles, nonce)) {
            let r = table::borrow(&state.completed_raffles, nonce);
            return RaffleStatusView {
                status: 2,
                creator: r.creator,
                winner: option::some(r.winner),
                prize_amount: r.prize_amount,
                asset_type: r.asset_type,
                participants_count: 0, 
                nonce,
                random_number: option::some(r.random_number)
            }
        };

        RaffleStatusView {
            status: 0,
            creator: @0x0,
            winner: option::none(),
            prize_amount: 0,
            asset_type: 0,
            participants_count: 0,
            nonce: 0,
            random_number: option::none()
        }
    }

    #[view]
    public fun get_treasury_address(): address acquires RaffleState {
        let state = borrow_global<RaffleState>(@roulette_addr);
        account::get_signer_capability_address(&state.treasury_cap)
    }

    #[view]
    public fun get_raffle_config(): (u64, address, address) acquires RaffleConfig {
        let config = borrow_global<RaffleConfig>(@roulette_addr);
        (config.creation_fee, config.fee_recipient, config.admin)
    }

    #[view]
    public fun get_creation_fee(): u64 acquires RaffleConfig {
        let config = borrow_global<RaffleConfig>(@roulette_addr);
        config.creation_fee
    }
}
