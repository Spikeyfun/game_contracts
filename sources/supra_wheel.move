module roulette_addr::supra_wheel {
    use std::string::{Self, String};
    use std::vector;
    use std::signer;
    use std::option::{Self, Option};
    use std::error;
    use aptos_std::table::{Self, Table};
    
    use supra_framework::coin::{Self};
    use supra_framework::supra_coin::SupraCoin;
    use supra_framework::account::{Self, SignerCapability};
    use supra_framework::object::{Self, Object};
    
    use supra_framework::fungible_asset::{Self, Metadata, FungibleStore, FungibleAsset};
    use supra_framework::primary_fungible_store;
    use supra_framework::dispatchable_fungible_asset;
    use supra_framework::event::{Self, EventHandle};
    use supra_framework::timestamp; 
    
    use aptos_token::token::{Self};           
    use aptos_token_objects::token as token_v2;        

    use supra_addr::supra_vrf;
    use supra_addr::deposit::{Self, SupraVRFPermit};
    use game_addr::vrf_manager; 

    // ==================================================================================
    //                                   CONSTANTS
    // ==================================================================================

    const E_NOT_ADMIN: u64 = 1;
    const E_GAME_NOT_FOUND: u64 = 3;
    const E_NO_PRIZES: u64 = 6;
    const E_METADATA_NOT_FOUND: u64 = 9;
    const E_INVALID_INDEX: u64 = 10;
    const E_PERMIT_MISSING: u64 = 11;

    const PRIZE_TYPE_FA: u8 = 1;      
    const PRIZE_TYPE_NFT_V1: u8 = 2;  
    const PRIZE_TYPE_NFT_V2: u8 = 3;  

    // ==================================================================================
    //                                   STRUCTS
    // ==================================================================================

    struct WheelClient has store {}

    struct WheelConfig has key {
        admin: address,
        fee_recipient: address,
        spin_fee: u64,
        is_paused: bool,
    }

    struct Prize has store, drop, copy {
        prize_type: u8,
        reward_amount: u64,                
        stock: u64, 
        object_address: Option<address>,         
        available_objects: vector<address>,      
        available_v1_ids: vector<token::TokenId>, 
        description: String,
        icon_url: String
    }

    struct PrizeInfo has drop, copy, store {
        prize_index: u64,
        prize_type_id: u8,      
        type_label: String,     
        token_name: String,     
        token_symbol: String,   
        reward_amount: u64,     
        decimals: u8,           
        stock: u64,
        description: String,    
        asset_address: String,
        icon_url: String
    }

    struct WheelState has key {
        prizes: vector<Prize>,
        treasury_cap: SignerCapability,
        vrf_permit: Option<SupraVRFPermit<WheelClient>>, 
        pending_spins: Table<u64, PendingSpin>, 
        completed_spins: Table<u64, SpinResult>,          
        player_active_nonces: Table<address, vector<u64>>, 
        spin_events: EventHandle<SpinEvent>,
        win_events: EventHandle<WinEvent>,
        refund_events: EventHandle<RefundEvent>,
    }

    struct PendingSpin has store, drop, copy {
        player: address, 
        fee_paid: u64, 
        timestamp: u64, 
    }

    struct SpinResult has store, drop, copy {
        nonce: u64, player: address, is_win: bool, prize_description: String, amount_won: u64, timestamp: u64
    }

    struct SpinEvent has drop, store { player: address, nonce: u64, fee: u64 }
    struct WinEvent has drop, store { player: address, nonce: u64, prize_desc: String, amount: u64 }
    struct RefundEvent has drop, store { player: address, nonce: u64, reason: String, amount: u64 }

    // ==================================================================================
    //                                INITIALIZATION
    // ==================================================================================

    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        let (resource_signer, resource_cap) = account::create_resource_account(deployer, b"supra_wheel_treasury_final_v5");
        let permit = deposit::init_vrf_module<WheelClient>(deployer);

        move_to(deployer, WheelConfig {
            admin: deployer_addr,
            fee_recipient: deployer_addr,
            spin_fee: 100_000_000, 
            is_paused: false,
        });

        move_to(deployer, WheelState {
            prizes: vector::empty(),
            treasury_cap: resource_cap,
            vrf_permit: option::some(permit), 
            pending_spins: table::new(),
            completed_spins: table::new(),
            player_active_nonces: table::new(),
            spin_events: account::new_event_handle<SpinEvent>(deployer),
            win_events: account::new_event_handle<WinEvent>(deployer),
            refund_events: account::new_event_handle<RefundEvent>(deployer),
        });

        if (!coin::is_account_registered<SupraCoin>(signer::address_of(&resource_signer))) {
            coin::register<SupraCoin>(&resource_signer);
        };

        token::initialize_token_store(&resource_signer);
        token::opt_in_direct_transfer(&resource_signer, true);
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
    //                                   GAME LOGIC
    // ==================================================================================

    public entry fun spin_wheel(player: &signer) acquires WheelConfig, WheelState {
        let player_addr = signer::address_of(player);
        let config = borrow_global<WheelConfig>(@roulette_addr);
        let state = borrow_global_mut<WheelState>(@roulette_addr);

        assert!(!config.is_paused, error::invalid_state(E_GAME_NOT_FOUND));
        assert!(vector::length(&state.prizes) > 0, error::invalid_state(E_NO_PRIZES));
        assert!(option::is_some(&state.vrf_permit), error::invalid_state(E_PERMIT_MISSING));

        let resource_addr = account::get_signer_capability_address(&state.treasury_cap);
        let (rng, conf, seed) = vrf_manager::authorize_and_get_config(resource_addr);

        // Charge Fee
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let resource_addr = signer::address_of(&resource_signer);
        if (config.spin_fee > 0) {
            let coins = coin::withdraw<SupraCoin>(player, config.spin_fee);
            coin::deposit(resource_addr, coins);
        };

        // Request Randomness
        let permit = option::borrow(&state.vrf_permit);
        let nonce = supra_vrf::rng_request_v2<WheelClient>(
            permit,
            string::utf8(b"fulfill_randomness"), 
            rng, seed, conf
        );

        // Save State
        let pending = PendingSpin { 
            player: player_addr, 
            fee_paid: config.spin_fee, 
            timestamp: timestamp::now_seconds() 
        };
        table::add(&mut state.pending_spins, nonce, pending);

        if (!table::contains(&state.player_active_nonces, player_addr)) {
            table::add(&mut state.player_active_nonces, player_addr, vector::empty<u64>());
        };
        vector::push_back(table::borrow_mut(&mut state.player_active_nonces, player_addr), nonce);

        event::emit_event(&mut state.spin_events, SpinEvent { 
            player: player_addr, nonce, fee: config.spin_fee 
        });
    }

    public entry fun fulfill_randomness(
        nonce: u64, message: vector<u8>, signature: vector<u8>, caller_address: address, rng_count: u8, client_seed: u64,
    ) acquires WheelConfig, WheelState {
        
        let verified = vrf_manager::verify_supra_callback(nonce, message, signature, caller_address, rng_count, client_seed);
        let random_val = *vector::borrow(&verified, 0);

        let state = borrow_global_mut<WheelState>(@roulette_addr);
        let config = borrow_global<WheelConfig>(@roulette_addr);

        if (!table::contains(&state.pending_spins, nonce)) return;
        
        let pending_spin = table::remove(&mut state.pending_spins, nonce);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let resource_addr = signer::address_of(&resource_signer);

        let prize_count = vector::length(&state.prizes);

        if (prize_count == 0) {
            let coins = coin::withdraw<SupraCoin>(&resource_signer, pending_spin.fee_paid);
            coin::deposit(pending_spin.player, coins);
            event::emit_event(&mut state.refund_events, RefundEvent { 
                player: pending_spin.player, nonce, reason: string::utf8(b"NO_PRIZES"), amount: pending_spin.fee_paid 
            });
            return
        };

        let winning_index = ((random_val % (prize_count as u256)) as u64);
        
        let (success_payment, should_remove, amount_won, prize_desc) = {
            let prize = vector::borrow_mut(&mut state.prizes, winning_index);
            
            let current_amount = prize.reward_amount;
            let current_desc = prize.description; 
            let local_success = false;
            let local_remove = false;

            // FUNGIBLE ASSET
            if (prize.prize_type == PRIZE_TYPE_FA) {
                if (option::is_some(&prize.object_address)) {
                    let asset_addr = *option::borrow(&prize.object_address);
                    let asset_obj = object::address_to_object<Metadata>(asset_addr);
                    if (primary_fungible_store::balance(resource_addr, asset_obj) >= current_amount) {
                        let treasury_store = primary_fungible_store::primary_store(resource_addr, asset_obj);
                        let prize_assets = internal_withdraw(&resource_signer, treasury_store, current_amount);
                        
                        let player_store = primary_fungible_store::ensure_primary_store_exists(pending_spin.player, asset_obj);
                        internal_deposit(player_store, prize_assets);

                        if (prize.stock > 0) {
                            prize.stock = prize.stock - 1;
                            if (prize.stock == 0) { local_remove = true; };
                        };
                        local_success = true;
                    };
                };
            // NFT V1 POOL
            } else if (prize.prize_type == PRIZE_TYPE_NFT_V1) {
                if (!vector::is_empty(&prize.available_v1_ids)) {
                    let token_id = vector::pop_back(&mut prize.available_v1_ids);
                    token::transfer(&resource_signer, token_id, pending_spin.player, 1);
                    local_success = true;
                    
                    if (vector::is_empty(&prize.available_v1_ids)) {
                        local_remove = true;
                    };
                };
            // NFT V2 POOL
            } else if (prize.prize_type == PRIZE_TYPE_NFT_V2) {
                if (!vector::is_empty(&prize.available_objects)) {
                    let obj_addr = vector::pop_back(&mut prize.available_objects);
                    let obj = object::address_to_object<token_v2::Token>(obj_addr);
                    object::transfer(&resource_signer, obj, pending_spin.player);
                    local_success = true;

                    if (vector::is_empty(&prize.available_objects)) {
                        local_remove = true;
                    };
                };
            };

            (local_success, local_remove, current_amount, current_desc)
        }; 

        if (should_remove) {
            let _ = vector::swap_remove(&mut state.prizes, winning_index);
        };

        if (success_payment) {
            event::emit_event(&mut state.win_events, WinEvent { 
                player: pending_spin.player, 
                nonce, 
                prize_desc, 
                amount: amount_won 
            });
            
            let fee_coins = coin::withdraw<SupraCoin>(&resource_signer, pending_spin.fee_paid);
            coin::deposit(config.fee_recipient, fee_coins);
            
            let res = SpinResult { 
                nonce, 
                player: pending_spin.player, 
                is_win: true, 
                prize_description: prize_desc, 
                amount_won, 
                timestamp: timestamp::now_seconds() 
            };
            table::add(&mut state.completed_spins, nonce, res);
        } else {
            let coins = coin::withdraw<SupraCoin>(&resource_signer, pending_spin.fee_paid);
            coin::deposit(pending_spin.player, coins);
            
            let res = SpinResult { 
                nonce, 
                player: pending_spin.player, 
                is_win: false, 
                prize_description: string::utf8(b"PAYMENT_ERROR"), 
                amount_won: 0, 
                timestamp: timestamp::now_seconds() 
            };
            table::add(&mut state.completed_spins, nonce, res);
        };
    }

    // ==================================================================================
    //                                ADMIN FUNCTIONS
    // ==================================================================================

    public entry fun donate_coin_to_pool<CoinType>(donor: &signer, amount: u64) acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let coins = coin::withdraw<CoinType>(donor, amount);
        let fa = coin::coin_to_fungible_asset(coins); 
        primary_fungible_store::deposit(signer::address_of(&resource_signer), fa);
    }

    public entry fun donate_fa_to_pool(donor: &signer, asset_address: address, amount: u64) acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let asset_obj = object::address_to_object<Metadata>(asset_address);
        let donor_addr = signer::address_of(donor);
        let donor_store = primary_fungible_store::primary_store(donor_addr, asset_obj);
        let assets = internal_withdraw(donor, donor_store, amount);

        let treasury_addr = signer::address_of(&resource_signer);
        let treasury_store = primary_fungible_store::ensure_primary_store_exists(treasury_addr, asset_obj);
        internal_deposit(treasury_store, assets);
    }

    public entry fun define_fa_prize(
        admin: &signer, 
        asset: address, 
        amount: u64, 
        stock: u64, 
        desc: String, 
        url: String
    ) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        
        vector::push_back(&mut state.prizes, Prize { 
            prize_type: PRIZE_TYPE_FA, 
            reward_amount: amount, 
            stock, 
            object_address: option::some(asset), 
            available_objects: vector::empty(),
            available_v1_ids: vector::empty(),
            description: desc, 
            icon_url: url 
        });
    }

    public entry fun define_coin_prize_by_type<CoinType>(
        admin: &signer, 
        amount: u64, 
        stock: u64, 
        desc: String, 
        url: String
    ) acquires WheelConfig, WheelState {
        let metadata = option::extract(&mut coin::paired_metadata<CoinType>());
        define_fa_prize(admin, object::object_address(&metadata), amount, stock, desc, url);
    }

    public entry fun add_v1_collection_prize(
        admin: &signer, 
        creator: address, 
        collection: String, 
        names: vector<String>,
        prop_ver: u64, 
        desc: String, 
        url: String
    ) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let resource_addr = signer::address_of(&resource_signer);

        let collected_ids = vector::empty<token::TokenId>();
        let i = 0;
        let len = vector::length(&names);
        
        while (i < len) {
            let name = *vector::borrow(&names, i);
            let token_id = token::create_token_id_raw(creator, collection, name, prop_ver);
            token::transfer(admin, token_id, resource_addr, 1);
            vector::push_back(&mut collected_ids, token_id);
            i = i + 1;
        };

        vector::push_back(&mut state.prizes, Prize {
            prize_type: PRIZE_TYPE_NFT_V1, 
            reward_amount: 1, 
            stock: len, 
            object_address: option::none(), 
            available_objects: vector::empty(),
            available_v1_ids: collected_ids, 
            description: desc, 
            icon_url: url
        });
    }

    public entry fun add_v2_collection_prize(
        admin: &signer, 
        obj_addrs: vector<address>, 
        desc: String, 
        url: String
    ) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);

        let i = 0;
        let len = vector::length(&obj_addrs);
        
        while (i < len) {
            let obj_addr = *vector::borrow(&obj_addrs, i);
            let object = object::address_to_object<token_v2::Token>(obj_addr);
            object::transfer(admin, object, signer::address_of(&resource_signer));
            i = i + 1;
        };
        
        vector::push_back(&mut state.prizes, Prize {
            prize_type: PRIZE_TYPE_NFT_V2, 
            reward_amount: 1, 
            stock: len, 
            object_address: option::none(), 
            available_objects: obj_addrs, 
            available_v1_ids: vector::empty(),
            description: desc, 
            icon_url: url
        });
    }

    public entry fun clear_all_prizes(admin: &signer) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        state.prizes = vector::empty();
    }

    public entry fun remove_prize_by_index(admin: &signer, index: u64) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        let len = vector::length(&state.prizes);
        assert!(index < len, error::invalid_argument(E_INVALID_INDEX));
        vector::swap_remove(&mut state.prizes, index);
    }

    public entry fun update_prize_stock(admin: &signer, index: u64, new_stock: u64) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        let len = vector::length(&state.prizes);
        assert!(index < len, error::invalid_argument(E_INVALID_INDEX));

        let prize = vector::borrow_mut(&mut state.prizes, index);
        prize.stock = new_stock; 
    }

    public entry fun withdraw_token_v1(
        admin: &signer, 
        creator: address, 
        collection: String, 
        name: String, 
        prop_ver: u64
    ) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        let token_id = token::create_token_id_raw(creator, collection, name, prop_ver);
        
        token::transfer(&resource_signer, token_id, config.admin, 1);
    }

    public entry fun withdraw_token_v2(
        admin: &signer, 
        object_addr: address
    ) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        
        let object = object::address_to_object<token_v2::Token>(object_addr);
        object::transfer(&resource_signer, object, config.admin);
    }

    public entry fun admin_withdraw_coin<CoinType>(admin: &signer, amount: u64) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        
        let coins = coin::withdraw<CoinType>(&resource_signer, amount);
        coin::deposit(config.admin, coins);
    }

    public entry fun withdraw_fungible_asset(
        admin: &signer, 
        asset_address: address, 
        amount: u64
    ) acquires WheelConfig, WheelState {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global<WheelState>(@roulette_addr);
        let resource_signer = account::create_signer_with_capability(&state.treasury_cap);
        
        let asset_metadata = object::address_to_object<Metadata>(asset_address);
        
        let resource_addr = signer::address_of(&resource_signer);
        let treasury_store = primary_fungible_store::primary_store(resource_addr, asset_metadata);
        
        let assets = internal_withdraw(&resource_signer, treasury_store, amount);
        
        let admin_store = primary_fungible_store::ensure_primary_store_exists(config.admin, asset_metadata);
        internal_deposit(admin_store, assets);
    }
    
    public entry fun clean_history(admin: &signer, nonces_to_remove: vector<u64>) acquires WheelState, WheelConfig {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        let state = borrow_global_mut<WheelState>(@roulette_addr);
        
        let i = 0;
        while (i < vector::length(&nonces_to_remove)) {
            let nonce = *vector::borrow(&nonces_to_remove, i);
            if (table::contains(&state.completed_spins, nonce)) {
                table::remove(&mut state.completed_spins, nonce);
            };
            i = i + 1;
        };
    }

    public entry fun set_config(
        admin: &signer, 
        new_fee: u64, 
        new_recipient: address, 
        is_paused: bool
    ) acquires WheelConfig {
        let config = borrow_global_mut<WheelConfig>(@roulette_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        config.spin_fee = new_fee;
        config.fee_recipient = new_recipient;
        config.is_paused = is_paused;
    }

    // ==================================================================================
    //                                   VIEW FUNCTIONS
    // ==================================================================================

    #[view]
    public fun get_prizes(): vector<PrizeInfo> acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        let prizes = &state.prizes;
        let results = vector::empty<PrizeInfo>();
        let i = 0;
        let len = vector::length(prizes);
        while (i < len) {
            let p = vector::borrow(prizes, i);
            let decimals_val: u8 = 0;
            let symbol_str = string::utf8(b"NFT");
            let name_str = p.description; 
            let type_label_str = string::utf8(b"Unknown");
            let asset_addr_str = string::utf8(b"N/A");
            
            let current_stock = if (p.prize_type == PRIZE_TYPE_NFT_V1) {
                vector::length(&p.available_v1_ids)
            } else if (p.prize_type == PRIZE_TYPE_NFT_V2) {
                vector::length(&p.available_objects)
            } else {
                p.stock
            };

            if (p.prize_type == PRIZE_TYPE_FA) {
                type_label_str = string::utf8(b"Fungible Asset");
                if (option::is_some(&p.object_address)) {
                    let addr = *option::borrow(&p.object_address);
                    asset_addr_str = string::utf8(b"FA_OBJECT"); 
                    let metadata_obj = object::address_to_object<Metadata>(addr);
                    symbol_str = fungible_asset::symbol(metadata_obj);
                    name_str = fungible_asset::name(metadata_obj);
                    decimals_val = fungible_asset::decimals(metadata_obj);
                };
            } else if (p.prize_type == PRIZE_TYPE_NFT_V1) {
                type_label_str = string::utf8(b"Legacy NFT Collection (V1)");
                asset_addr_str = string::utf8(b"POOL_V1");
            } else if (p.prize_type == PRIZE_TYPE_NFT_V2) {
                type_label_str = string::utf8(b"Digital Asset Collection (V2)");
                asset_addr_str = string::utf8(b"POOL_V2");
            };

            let info = PrizeInfo { 
                prize_index: i, 
                prize_type_id: p.prize_type, 
                type_label: type_label_str, 
                token_name: name_str,
                token_symbol: symbol_str, 
                reward_amount: p.reward_amount, 
                decimals: decimals_val, 
                stock: current_stock,
                description: p.description, 
                asset_address: asset_addr_str, 
                icon_url: *&p.icon_url 
            };
            vector::push_back(&mut results, info);
            i = i + 1;
        };
        results
    }

    #[view]
    public fun get_spin_fee(): u64 acquires WheelConfig {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        config.spin_fee
    }

    #[view]
    public fun get_game_config(): (u64, bool, address, address) acquires WheelConfig {
        let config = borrow_global<WheelConfig>(@roulette_addr);
        (config.spin_fee, config.is_paused, config.admin, config.fee_recipient)
    }

    #[view]
    public fun get_spin_result(nonce: u64): Option<SpinResult> acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        if (table::contains(&state.completed_spins, nonce)) {
            option::some(*table::borrow(&state.completed_spins, nonce))
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_last_pending_nonce(player_addr: address): Option<u64> acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        if (table::contains(&state.player_active_nonces, player_addr)) {
            let nonces = table::borrow(&state.player_active_nonces, player_addr);
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
    public fun get_treasury_address(): address acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        account::get_signer_capability_address(&state.treasury_cap)
    }

    #[view]
    public fun get_pending_spin_info(nonce: u64): Option<PendingSpin> acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        if (table::contains(&state.pending_spins, nonce)) {
            option::some(*table::borrow(&state.pending_spins, nonce))
        } else {
            option::none()
        }
    }

    #[view]
    public fun get_all_active_nonces_for_player(player_addr: address): vector<u64> acquires WheelState {
        let state = borrow_global<WheelState>(@roulette_addr);
        if (table::contains(&state.player_active_nonces, player_addr)) {
            *table::borrow(&state.player_active_nonces, player_addr)
        } else {
            vector::empty()
        }
    }
}
