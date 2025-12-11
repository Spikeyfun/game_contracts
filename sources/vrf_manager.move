module game_addr::vrf_manager {
    use std::signer;
    use std::vector;
    use std::error;
    
    use supra_framework::account::{Self, SignerCapability}; 
    use supra_framework::coin;
    use supra_framework::supra_coin::{SupraCoin}; 
    
    use supra_addr::supra_vrf;
    use supra_addr::deposit;

    // === Errors ===
    const E_NOT_ADMIN: u64 = 1;
    const E_NOT_AUTHORIZED: u64 = 2;

    struct VRFGlobalConfig has key {
        admin: address,
        vrf_rng_count: u8,
        vrf_client_seed: u64,
        vrf_confirmations: u64,
    }

    struct AuthorizedApps has key {
        whitelist: vector<address> 
    }

    struct TreasuryInfo has key {
        treasury_cap: SignerCapability 
    }

    fun init_module(deployer: &signer) {
        let deployer_addr = signer::address_of(deployer);
        
        deposit::whitelist_client_address(deployer, 100_000_000); 

        move_to(deployer, VRFGlobalConfig {
            admin: deployer_addr,
            vrf_rng_count: 1,
            vrf_client_seed: 0, 
            vrf_confirmations: 1,
        });

        move_to(deployer, AuthorizedApps {
            whitelist: vector::empty()
        });

        let (_, resource_cap) = account::create_resource_account(deployer, x"01");
        let resource_signer = account::create_signer_with_capability(&resource_cap);
        
        if (!coin::is_account_registered<SupraCoin>(signer::address_of(&resource_signer))) {
            coin::register<SupraCoin>(&resource_signer);
        };
        
        move_to(deployer, TreasuryInfo { treasury_cap: resource_cap });
    }

    // === INTERNAL WHITELIST MANAGEMENT ===

    public entry fun add_game_to_whitelist(admin: &signer, game_address: address) acquires VRFGlobalConfig, AuthorizedApps {
        let config = borrow_global<VRFGlobalConfig>(@game_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));

        let apps = borrow_global_mut<AuthorizedApps>(@game_addr);
        if (!vector::contains(&apps.whitelist, &game_address)) {
            vector::push_back(&mut apps.whitelist, game_address);
        };
    }

    public entry fun remove_game_from_whitelist(admin: &signer, game_address: address) acquires VRFGlobalConfig, AuthorizedApps {
        let config = borrow_global<VRFGlobalConfig>(@game_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));

        let apps = borrow_global_mut<AuthorizedApps>(@game_addr);
        let (found, index) = vector::index_of(&apps.whitelist, &game_address);
        if (found) {
            vector::remove(&mut apps.whitelist, index);
        };
    }

    // === GLOBAL CONFIGURATION ===

    public entry fun update_config(
        admin: &signer,
        rng_count: u8,
        client_seed: u64,
        confirmations: u64
    ) acquires VRFGlobalConfig {
        let config = borrow_global_mut<VRFGlobalConfig>(@game_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));
        
        config.vrf_rng_count = rng_count;
        config.vrf_client_seed = client_seed;
        config.vrf_confirmations = confirmations;
    }

    // === CORE: AUTHORIZATION ===
    public fun authorize_and_get_config(caller_address: address): (u8, u64, u64) acquires AuthorizedApps, VRFGlobalConfig {
        let apps = borrow_global<AuthorizedApps>(@game_addr);
        assert!(vector::contains(&apps.whitelist, &caller_address), error::permission_denied(E_NOT_AUTHORIZED));

        let config = borrow_global<VRFGlobalConfig>(@game_addr);
        (config.vrf_rng_count, config.vrf_confirmations, config.vrf_client_seed)
    }

    // === CORE: SUPRA CALLBACK VERIFICATION ===
    public fun verify_supra_callback(
        nonce: u64, message: vector<u8>, signature: vector<u8>, caller_address: address, rng_count: u8, client_seed: u64
    ): vector<u256> {
        supra_vrf::verify_callback(nonce, message, signature, caller_address, rng_count, client_seed)
    }

    // === SUPRA FUND MANAGEMENT ===

    public entry fun deposit_to_supra(
        funder: &signer, 
        amount: u64
    ) {
        deposit::deposit_fund_v2(funder, @game_addr, amount);
    }

    public entry fun withdraw_from_dvrf(
        admin: &signer, 
        amount: u64
    ) acquires VRFGlobalConfig {
        let config = borrow_global<VRFGlobalConfig>(@game_addr);
        let admin_addr = signer::address_of(admin);

        assert!(admin_addr == config.admin, error::permission_denied(E_NOT_ADMIN));        
        assert!(admin_addr == @game_addr, error::permission_denied(E_NOT_AUTHORIZED));

        deposit::withdraw_fund(admin, amount);
    }

    public entry fun auto_refill_supra_balance(admin: &signer, amount: u64) acquires VRFGlobalConfig, TreasuryInfo {
        let config = borrow_global<VRFGlobalConfig>(@game_addr);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(E_NOT_ADMIN));

        let treasury = borrow_global<TreasuryInfo>(@game_addr);
        let resource_signer = account::create_signer_with_capability(&treasury.treasury_cap);
        
        deposit::deposit_fund_v2(&resource_signer, @game_addr, amount);
    }

    // ==================================================================================
    //                                   VIEW FUNCTIONS
    // ==================================================================================

    #[view]
    public fun get_admin(): address acquires VRFGlobalConfig {
        borrow_global<VRFGlobalConfig>(@game_addr).admin
    }

    #[view]
    public fun get_manager_address(): address acquires TreasuryInfo {
        let info = borrow_global<TreasuryInfo>(@game_addr);
        account::get_signer_capability_address(&info.treasury_cap)
    }

    #[view]
    public fun is_game_whitelisted(game_address: address): bool acquires AuthorizedApps {
        let apps = borrow_global<AuthorizedApps>(@game_addr);
        vector::contains(&apps.whitelist, &game_address)
    }

    #[view]
    public fun get_global_config(): (address, u8, u64, u64) acquires VRFGlobalConfig {
        let config = borrow_global<VRFGlobalConfig>(@game_addr);
        (config.admin, config.vrf_rng_count, config.vrf_client_seed, config.vrf_confirmations)
    }

    #[view]
    public fun get_subscription_health(client_address: address): (u64, u64, u64, bool) {
        let total = deposit::check_client_fund(client_address);
        let minimum = deposit::check_min_balance_client_v2(client_address);
        let effective = deposit::check_effective_balance_v2(client_address);
        let at_minimum = deposit::has_minimum_balance_reached_v2(client_address);
        
        (total, minimum, effective, at_minimum)
    }
}
