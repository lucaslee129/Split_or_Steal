/*
    The quest is a representation of Prisoners Dilemma game from game theory. The contract deployer can create a game
    providing addresses of two players that will take part in the game and sends funds to the smart contract, that will
    be a prize for participating in the game. Next, both players submit their decisions representing their intentions to
    either try to split or try to steal the prize. After that, they have a fixed amount of time to reveal their
    decisions. There are multiple possible outcomes of the game:
        - Both players decide to split the prize. Both players receive half of the prize
        - One of the players decides to split and the other one to steal. The player that decided to steal gets
            the whole prize, while the other one gets nothing
        - Both players decide to steal the prize. The prize is transferred back to the contract deployer and
            both players get nothing
        - Only one player reveals the decision on time. The player that revealed the decision gets the prize and
            the other gets nothing
        - No one reveals the decision on time. The prize is transferred back to the contract deployer and
            both players get nothing
*/

module overmind::split_or_steal {

    //==============================================================================================
    // Dependencies
    //==============================================================================================

    use std::bcs;
    use std::hash;
    use std::option::{Self, Option};
    use std::signer;
    use std::string::{Self, String};
    use std::vector;

    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::coin;
    use aptos_framework::event::{Self, EventHandle};
    use aptos_framework::timestamp;

    #[test_only]
    use aptos_framework::aptos_coin;
    #[test_only]
    use aptos_framework::guid;
    #[test_only]
    use std::hash::sha3_256;

    //==============================================================================================
    // Constants - DO NOT MODIFY
    //==============================================================================================

    const SEED: vector<u8> = b"SplitOrSteal";
    const EXPIRATION_TIME_IN_SECONDS: u64 = 60 * 60;

    const DECISION_NOT_MADE: u64 = 0;
    const DECISION_SPLIT: u64 = 1;
    const DECISION_STEAL: u64 = 2;

    //==============================================================================================
    // Error codes
    //==============================================================================================

    const EStateIsNotInitialized: u64 = 0;
    const ESignerIsNotDeployer: u64 = 1;
    const ESignerHasInsufficientAptBalance: u64 = 2;
    const EGameDoesNotExist: u64 = 3;
    const EPlayerDoesNotParticipateInTheGame: u64 = 4;
    const EIncorrectHashValue: u64 = 5;
    const EGameNotExpiredYet: u64 = 6;
    const EBothPlayersDoNotHaveDecisionsSubmitted: u64 = 7;
    const EPlayerHasDecisionSubmitted: u64 = 8;

    //==============================================================================================
    // Module Structs
    //==============================================================================================

    /*
        The main resource holding data about all games and events
    */
    struct State has key {
        // ID of the next game that will be created
        next_game_id: u128,
        // A map of games
        games: SimpleMap<u128, Game>,
        // Resource account's SignerCapability instance
        cap: SignerCapability,
        // Events
        create_game_events: EventHandle<CreateGameEvent>,
        submit_decision_events: EventHandle<SubmitDecisionEvent>,
        reveal_decision_events: EventHandle<RevealDecisionEvent>,
        conclude_game_events: EventHandle<ConcludeGameEvent>,
        release_funds_after_expiration_events: EventHandle<ReleaseFundsAfterExpirationEvent>
    }

    /*
        A struct representing a single game
    */
    struct Game has store, copy, drop {
        // Amount of APT that can be won
        prize_pool_amount: u64,
        // Instance of PlayerData representing the first player
        player_one: PlayerData,
        // Instance of PlayerData representing the second player
        player_two: PlayerData,
        // Timestamp, after which a game can be terminated calling `release_funds_after_expiration` function
        expiration_timestamp_in_seconds: u64,
    }

    /*
        A struct representing a player
    */
    struct PlayerData has store, copy, drop {
        // Address of the player
        player_address: address,
        // Hash of the player's decision created from the decision and the player's salt
        decision_hash: Option<vector<u8>>,
        // Hash of the player's salt
        salt_hash: Option<vector<u8>>,
        // Decision made by the player (can be either DECISION_NOT_MADE, DECISION_SPLIT or DECISION_STEAL)
        decision: u64
    }

    //==============================================================================================
    // Event structs
    //==============================================================================================

    /*
        Event emitted in every `create_game` function call
    */
    struct CreateGameEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Amount of APT that can be won
        prize_pool_amount: u64,
        // Address of the first player
        player_one_address: address,
        // Address of the second player
        player_two_address: address,
        // Timestamp, after which a game can be terminated calling `release_funds_after_expiration` function
        expiration_timestamp_in_seconds: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in every `submit_decision` function call
    */
    struct SubmitDecisionEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Address of the player calling the function
        player_address: address,
        // Hash of the player's decision created from the decision and the player's salt
        decision_hash: vector<u8>,
        // Hash of the player's salt
        salt_hash: vector<u8>,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in every `reveal_decision` function call
    */
    struct RevealDecisionEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Address of the player calling the function
        player_address: address,
        // Decision made by the player (either DECISION_SPLIT or DECISION_STEAL)
        decision: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in `reveal_decision` function call if both players' decisions were revealed
    */
    struct ConcludeGameEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Decision made by the first player (either DECISION_SPLIT or DECISION_STEAL)
        player_one_decision: u64,
        // Decision made by the second player (either DECISION_SPLIT or DECISION_STEAL)
        player_two_decision: u64,
        // Amount of APT that could be won in the game
        prize_pool_amount: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    /*
        Event emitted in every `release_funds_after_expiration` function call
    */
    struct ReleaseFundsAfterExpirationEvent has store, drop {
        // ID of the game
        game_id: u128,
        // Decision made by the first player (either DECISION_NOT_MADE, DECISION_SPLIT or DECISION_STEAL)
        player_one_decision: u64,
        // Decision made by the second player (either DECISION_NOT_MADE, DECISION_SPLIT or DECISION_STEAL)
        player_two_decision: u64,
        // Amount of APT that could be won in the game
        prize_pool_amount: u64,
        // Timestamp, when the event was created
        event_creation_timestamp_in_seconds: u64
    }

    //==============================================================================================
    // Functions
    //==============================================================================================

    /*
        Function called at the deployment of the module
        @param account - deployer of the module
    */
    fun init_module(account: &signer) {
        // TODO: Create a resource account (utilize SEED const)
		let (res_signer, res_account_capability) = account::create_resource_account(account, SEED);
        // TODO: Register the resource account with AptosCoin
        coin::register<AptosCoin>(&res_signer);

        // TODO: Create a new State instance and move it to `account` signer

        let newState = State{
            next_game_id: 0,
            games: simple_map::create(),
            cap: res_account_capability,
            create_game_events: account::new_event_handle(account),
            submit_decision_events: account::new_event_handle(account),
            reveal_decision_events: account::new_event_handle(account),
            conclude_game_events: account::new_event_handle(account),
            release_funds_after_expiration_events: account::new_event_handle(account)
        };

        move_to(account, newState);
    }

    /*
        Creates a new game
        @param account - deployer of the module
        @param prize_pool_amount - amout of APT that can be won in the game
        @param player_one_address - address of the first player participating in the game
        @param player_two_address - address of the second player participating in the game
    */
    public entry fun create_game(
        account: &signer,
        prize_pool_amount: u64,
        player_one_address: address,
        player_two_address: address
    ) acquires State {
        // TODO: Call `check_if_state_exists` function
        check_if_state_exists();

        // TODO: Call `check_if_signer_is_contract_deployer` function
        check_if_signer_is_contract_deployer(account);

        // TODO: Call `check_if_signer_has_enough_apt_coins` function
        check_if_account_has_enough_apt_coins(account, prize_pool_amount);

        // TODO: Call `get_next_game_id` function
        let next_game_id_counter = 0;
        let next_game_id = get_next_game_id(&mut next_game_id_counter);

        // TODO: Create a new instance of Game

        let initSalt = b"bbbyyy";
        let initDecision = b"ddssdd";

        let initPlayerOneData = PlayerData{
            player_address: player_one_address,
            decision_hash: option::some(hash::sha3_256(initSalt)),
            salt_hash: option::some(hash::sha3_256(initDecision)),
            decision: DECISION_NOT_MADE
        };

        let initPlayerTwoData = PlayerData{
            player_address: player_two_address,
            decision_hash: option::some(hash::sha3_256(initSalt)),
            salt_hash: option::some(hash::sha3_256(initDecision)),
            decision: DECISION_NOT_MADE
        };

        let initCreateGameEvent = CreateGameEvent {
            game_id : 0,
            prize_pool_amount: 0,
            player_one_address : @0x0,
            player_two_address : @0x0,
            expiration_timestamp_in_seconds : EXPIRATION_TIME_IN_SECONDS,
            event_creation_timestamp_in_seconds : 0
        };

        let new_Game = Game {
            prize_pool_amount: prize_pool_amount,
            player_one: initPlayerOneData,
            player_two: initPlayerTwoData,
            expiration_timestamp_in_seconds: EXPIRATION_TIME_IN_SECONDS
        };

        // TODO: Add the game to the State's games SimpleMap instance
        let gameState = &mut borrow_global_mut<State>(signer::address_of(account)).games;
        simple_map::add(gameState, next_game_id, new_Game);

        // TODO: Transfer `prize_pool_amount` amount of APT from `account` to the resource account
        let res_addr = account::create_resource_address( &signer::address_of(account), SEED);
        coin::transfer<AptosCoin>(account, res_addr, prize_pool_amount);

        // TODO: Emit `CreateGameEvent` event
        let state = borrow_global_mut<State>(@overmind);

        event::emit_event<CreateGameEvent>(&mut state.create_game_events, CreateGameEvent{
            game_id: next_game_id,
            prize_pool_amount: prize_pool_amount,
            player_one_address: player_one_address,
            player_two_address: player_two_address,
            expiration_timestamp_in_seconds:EXPIRATION_TIME_IN_SECONDS,
            event_creation_timestamp_in_seconds : timestamp::now_seconds()
        });
    }

    /*
        Saves a player's decision in their PlayerData instance in the game with the provided `game_id`
        @param player - player participating in the game
        @param game_id - ID of the game
        @param decision_hash - SHA3_256 hash of combination of the player's decision and the player's salt
        @param salt_hash - SHA3_256 hash of the player's salt
    */
    public entry fun submit_decision(
        player: &signer,
        game_id: u128,
        decision_hash: vector<u8>,
        salt_hash: vector<u8>
    ) acquires State {
        // TODO: Call `check_if_state_exists` function
        check_if_state_exists();

        // TODO: Call `check_if_game_exists` function
        let gameStateAddress = &borrow_global_mut<State>(signer::address_of(player)).games;
        check_if_game_exists(gameStateAddress, &game_id);

        // TODO: Call `check_if_player_participates_in_the_game` function
        let gameInstance = simple_map::borrow(gameStateAddress, &game_id);
        check_if_player_participates_in_the_game(player, gameInstance);

        // TODO: Call `check_if_player_does_not_have_a_decision_submitted` function
        check_if_player_does_not_have_a_decision_submitted(gameInstance, signer::address_of(player));

        //  TODO: Set the player's PlayerData decision_hash and salt_hash fields to the values provided in the params
       let playerOneInstance = gameInstance.player_one;
       let playerTwoInstance = gameInstance.player_two;

       if(signer::address_of(player) == playerOneInstance.player_address) {
        playerOneInstance.decision_hash = option::some(decision_hash);
        playerOneInstance.salt_hash = option::some(salt_hash);
       } else if (signer::address_of(player) == playerTwoInstance.player_address) {
        playerTwoInstance.decision_hash = option::some(decision_hash);
        playerTwoInstance.salt_hash = option::some(salt_hash);
       };

        // TODO: Emit `SubmitDecisionEvent` event
        let state = borrow_global_mut<State>(@overmind);

        event::emit_event<SubmitDecisionEvent>(&mut state.submit_decision_events, SubmitDecisionEvent {
            game_id: game_id,
            player_address: signer::address_of(player),
            decision_hash: decision_hash,
            salt_hash: salt_hash,
            event_creation_timestamp_in_seconds: timestamp::now_seconds()
        });
    }

    /*
        Reveals the decision made by a player in `submit_decision` function and concludes the game if both players
        call this function.
        @param player - player participating in the game
        @param game_id - ID of the game
        @param salt - salt that the player used to hash their decision
    */
    public entry fun reveal_decision(
        player: &signer,
        game_id: u128,
        salt: String
    ) acquires State {
        // TODO: Call `check_if_state_exists` function
        check_if_state_exists();

        // TODO: Call `check_if_game_exists` function
        let gameStateAddress = &borrow_global_mut<State>(signer::address_of(player)).games;
        check_if_game_exists(gameStateAddress, &game_id);

        // TODO: Call `check_if_player_participates_in_the_game` function
        let gameInstance = simple_map::borrow(gameStateAddress, &game_id);
        check_if_player_participates_in_the_game(player, gameInstance);

        // TODO: Call `check_if_both_players_have_a_decision_submitted` function
        check_if_both_players_have_a_decision_submitted(gameInstance);

        // TODO: Call `make_decision` function with appropriate PlayerData instance depending on the player's address

        let playerOneInstance = gameInstance.player_one;
        let playerTwoInstance = gameInstance.player_two;
        let prize_Game = gameInstance.prize_pool_amount;
        let decision_res;

        if(signer::address_of(player) == playerOneInstance.player_address) {
            decision_res = make_decision(&mut playerOneInstance, &salt);
            playerOneInstance.decision = decision_res;
        } else if (signer::address_of(player) == playerTwoInstance.player_address) {
            decision_res = make_decision(&mut playerOneInstance, &salt);
            playerTwoInstance.decision = decision_res;
        } else
            decision_res = DECISION_NOT_MADE;

        // TODO: Emit `RevealDecisionEvent` event
        let state = borrow_global_mut<State>(@overmind);

        event::emit_event<RevealDecisionEvent>(&mut state.reveal_decision_events, RevealDecisionEvent {
            game_id: game_id,
            player_address: signer::address_of(player),
            decision: decision_res,
            event_creation_timestamp_in_seconds : timestamp::now_seconds()
        });

        // TODO: If both players submitted their decisions:
        //      1) Remove the game from the State's game SimpleMap instance
        let willRemoveGame = &mut borrow_global_mut<State>(@overmind).games;
        let (remmovedKey, removedValue)  = simple_map::remove(willRemoveGame, &game_id);
        let player_one_decision = playerOneInstance.decision;
        let player_two_decision = playerTwoInstance.decision;

        //      2) If both players decided to split, send half of the game's `prize_pool_amount` of APT to both of them
        let res_addr = account::create_resource_address(&signer::address_of(player), SEED);
        if(player_one_decision == DECISION_SPLIT && player_two_decision == DECISION_SPLIT) {
            coin::transfer<AptosCoin>(player, playerOneInstance.player_address, prize_Game / 2);
            coin::transfer<AptosCoin>(player, playerTwoInstance.player_address, prize_Game / 2);
        }

        //      3) If one of the players decided to steal and the other one to split, send
        //          the game's `prize_pool_amount` of APT to the player that decided to steal
        else if(player_one_decision == DECISION_SPLIT && player_two_decision == DECISION_STEAL) {
            coin::transfer<AptosCoin>(player, playerTwoInstance.player_address, prize_Game);
        } else if(player_one_decision == DECISION_STEAL && player_two_decision == DECISION_SPLIT) {
            coin::transfer<AptosCoin>(player, playerOneInstance.player_address, prize_Game);
        }

        //      4) If both players decided to steal, send the game's `prize_pool_amount` of APT to the deployer of the contract
        else if (player_one_decision == DECISION_STEAL && player_two_decision == DECISION_STEAL) {
            coin::transfer<AptosCoin>(player, signer::address_of(player), prize_Game);
        };

        //      5) Emit `ConcludeGameEvent` event
        let state = borrow_global_mut<State>(@overmind);

        event::emit_event<ConcludeGameEvent>(&mut state.conclude_game_events, ConcludeGameEvent {
            game_id: 0,
            player_one_decision : player_one_decision,
            player_two_decision : player_two_decision,
            prize_pool_amount : prize_Game,
            event_creation_timestamp_in_seconds : timestamp::now_seconds()
        });

    }

    /*
        Releases the funds if a game expired depending on revealed decisions
        @param _account - any account signer
        @param game_id - ID of the game
    */
    public entry fun release_funds_after_expiration(_account: &signer, game_id: u128) acquires State {
        // TODO: Call `check_if_state_exists` function
        check_if_state_exists();

        // TODO: Call `check_if_game_exists` function
        let gameStateAddress = &mut borrow_global_mut<State>(signer::address_of(_account)).games;
        check_if_game_exists(gameStateAddress, &game_id);

        // TODO: Remove the game from the State's games SimpleMap instance
        let (remmovedKey, removedValue)  = simple_map::remove(gameStateAddress, &game_id);

        // TODO: Call `check_if_game_expired` function
        check_if_game_expired(&removedValue);
        // TODO: Transfer the game's `prize_pool_amount` APT amount to:
        //      1) The deployer of the contract if the both players' decisions were not releaved
        //      2) The first player if the second player did not releave their decision
        //      3) The second player if the first player did not releave their decision
        let gameStateAddress = &borrow_global_mut<State>(signer::address_of(_account)).games;
        let gameInstance = simple_map::borrow(gameStateAddress, &game_id);
        let playerOneInstance = gameInstance.player_one;
        let playerTwoInstance = gameInstance.player_two;
        let prize_Game = gameInstance.prize_pool_amount;

        if(playerOneInstance.decision != DECISION_NOT_MADE && playerTwoInstance.decision != DECISION_NOT_MADE) {
            coin::transfer<AptosCoin>(_account, signer::address_of(_account), prize_Game);
        } else if(playerOneInstance.decision == DECISION_NOT_MADE && playerTwoInstance.decision != DECISION_NOT_MADE) {
            coin::transfer<AptosCoin>(_account, playerOneInstance.player_address, prize_Game);
        } else if(playerOneInstance.decision != DECISION_NOT_MADE && playerTwoInstance.decision == DECISION_NOT_MADE) {
            coin::transfer<AptosCoin>(_account, playerTwoInstance.player_address, prize_Game);
        };

        // TODO: Emit `ReleaseFundsAfterExpirationEvent` event
        let state = borrow_global_mut<State>(@overmind);

        event::emit_event<ReleaseFundsAfterExpirationEvent>(&mut state.release_funds_after_expiration_events, ReleaseFundsAfterExpirationEvent {
            game_id : game_id,
            player_one_decision : playerOneInstance.decision,
            player_two_decision : playerTwoInstance.decision,
            prize_pool_amount : prize_Game,
            event_creation_timestamp_in_seconds : timestamp::now_seconds()
        });

    }

    //==============================================================================================
    // Helper functions
    //==============================================================================================

    /*
        Sets the PlayerData's decision field's value to either DECISION_SPLIT or DECISION_STEAL depending on value of
        the PlayerData's decision_hash value
        @param player_data - instance of PlayerData struct
        @param salt - salt that the player used to hash their decision
        @return - the decision made and submitted in `submit_decision` function
            (either DECISION_SPLIT or DECISION_STEAL)
    */
    inline fun make_decision(player_data: &mut PlayerData, salt: &String): u64 {
        // TODO: Call `check_if_hash_is_correct` function
        check_if_state_exists();

        // TODO: Create a SHA3_256 hash of a split decision from a vector containing serialized DECISION_SPLIT const
        //      and bytes of the salt
        let decision_split = bcs::to_bytes(&DECISION_SPLIT);
        let salt = bcs::to_bytes(salt);
        vector::append(&mut decision_split, salt);
        let splitDecision = hash::sha3_256(decision_split);

        // TODO: Create a SHA3_256 hash of a steal decision from a vector containing serialized DECISION_STEAL const
        //      and bytes of the salt
        let decision_steal = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut decision_steal, salt);
        let stealDecision = hash::sha3_256(decision_steal);

        // TODO: Compare the hashes with the PlayerData's `decision_hash` and return either DECISION_SPLIT
        //      or DECISION_STEAL depending on the result
        if(player_data.decision_hash == option::some(splitDecision)) {
            DECISION_SPLIT
        } else if(player_data.decision_hash == option::some(stealDecision)){
            DECISION_STEAL
        } else {
            DECISION_NOT_MADE
        }
    }

    /*
        Increments `next_game_id` param and returns its previous value
        @param next_game_id - `next_game_id` field from State resource
        @return - value of `next_game_id` field from State resource before the increment
    */
    inline fun get_next_game_id(next_game_id: &mut u128): u128 {
        // TODO: Create a variable holding a copy of current value of `next_game_id` param
        let currentGameId = next_game_id;
        let temp : u128 = *currentGameId;
        *currentGameId = *currentGameId + 1;
        // TODO: Increment `next_game_id` param
        // *next_game_id = *next_game_id + 1;
        // TODO: Return the previously created variable
        temp
    }

    //==============================================================================================
    // Validation functions
    //==============================================================================================

    inline fun check_if_state_exists() {
        // TODO: Assert that State resource exists under the contract deployer's address
        assert!(exists<State>(@0x1234), 1);
    }


    inline fun check_if_signer_is_contract_deployer(signer: &signer) {
        // TODO: Assert that address of `signer` is the same as address of `overmind` located in Move.toml file
        // assert!(signer == 0x1234 as address)
        assert!(signer::address_of(signer) == @0x1234, 2);
    }

    inline fun check_if_account_has_enough_apt_coins(account: &signer, amount: u64) {
        // TODO: Assert that AptosCoin balance of `account` address equals or is greater that `amount` param
        let addr_Account = signer::address_of(account);
        assert!((coin::balance<AptosCoin>(addr_Account)) >= amount, 3);
    }

    inline fun check_if_game_exists(games: &SimpleMap<u128, Game>, game_id: &u128) {
        // TODO: Assert that `game` SimpleMap contains `game_id` key
        use std::vector::contains;
        assert!(simple_map::contains_key(games, game_id), 4);
    }

    inline fun check_if_player_participates_in_the_game(player: &signer, game: &Game) {
        // TODO: Assert that address of `player` is the same as either address of the first player or address of
        //      the second player stored in the Game instance
        assert!(signer::address_of(player) == game.player_one.player_address || signer::address_of(player) == game.player_two.player_address, 5);
    }

    inline fun check_if_both_players_have_a_decision_submitted(game: &Game) {
        // TODO: Assert that both PlayerData's `decision_hash` fields are option::some
        let decision_one = game.player_one.decision_hash;
        let decision_two = game.player_two.decision_hash;
        assert!(option::is_none(&decision_one) && option::is_none(&decision_two), 6);

    }

    inline fun check_if_player_does_not_have_a_decision_submitted(game: &Game, player_address: address) {
        // TODO: Assert that the player's PlayerData's `decision_hash` is option::none depending on `player_address`
        //      param's value
        // TODO: Abort with `EPlayerDoesNotParticipateInTheGame` code if `player_address` param's value does not match
        //      any address of the players participating in the game

        let decision_one = game.player_one.decision_hash;
        let decision_two = game.player_two.decision_hash;

        assert!(option::is_none(&decision_one) ||option::is_none(&decision_two), 7);
        if(player_address != game.player_one.player_address && player_address != game.player_two.player_address) abort EPlayerDoesNotParticipateInTheGame;
    }

    inline fun check_if_hash_is_correct(hash: vector<u8>, value: vector<u8>) {
        // TODO: Assert that `hash` param equals SHA3_256 hash of `value` param
        assert!(hash == hash::sha3_256(value), 8);

    }

    inline fun check_if_game_expired(game: &Game) {
        // TODO: Assert that the Game's `expiration_timestamp_in_seconds` is smaller than current timestamp
        assert!(game.expiration_timestamp_in_seconds < EXPIRATION_TIME_IN_SECONDS, 9);
    }

    //==============================================================================================
    // Tests - DO NOT MODIFY
    //==============================================================================================

    #[test]
    fun test_init() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 0, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 0, 2);
        assert!(event::counter(&state.submit_decision_events) == 0, 3);
        assert!(event::counter(&state.reveal_decision_events) == 0, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 6);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(event::guid(&state.submit_decision_events)) == resource_account_address,
            8
        );
        assert!(guid::creator_address(event::guid(&state.reveal_decision_events)) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );
        assert!(coin::is_account_registered<AptosCoin>(resource_account_address), 12);
        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 13);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 524303, location = aptos_framework::account)]
    fun test_init_again() {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);
        init_module(&account);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_create_game() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 1, 1);
        assert!(simple_map::contains_key(&state.games, &0), 2);
        assert!(event::counter(&state.create_game_events) == 1, 3);
        assert!(event::counter(&state.submit_decision_events) == 0, 4);
        assert!(event::counter(&state.reveal_decision_events) == 0, 5);
        assert!(event::counter(&state.conclude_game_events) == 0, 6);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            8
        );
        assert!(
            guid::creator_address(event::guid(&state.submit_decision_events)) == resource_account_address,
            9
        );
        assert!(guid::creator_address(event::guid(&state.reveal_decision_events)) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            11
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            12
        );

        let game = *simple_map::borrow(&state.games, &0);
        assert!(game.prize_pool_amount == prize_pool_amount, 13);
        assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);
        assert!(game.player_one.player_address == player_one_address, 15);
        assert!(option::is_none(&game.player_one.decision_hash), 16);
        assert!(option::is_none(&game.player_one.salt_hash), 17);
        assert!(game.player_one.decision == DECISION_NOT_MADE, 18);

        assert!(game.player_two.player_address == player_two_address, 19);
        assert!(option::is_none(&game.player_two.decision_hash), 20);
        assert!(option::is_none(&game.player_two.salt_hash), 21);
        assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 25);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_create_game_state_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@overmind);
        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);
    }

    #[test]
    #[expected_failure(abort_code = 1, location = Self)]
    fun test_create_game_signer_is_not_deployer() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let account = account::create_account_for_test(@0x6234834325);
        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);
    }

    #[test]
    #[expected_failure(abort_code = 2, location = Self)]
    fun test_create_game_signer_has_insufficient_apt_balance() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_submit_decision() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_one, 0, decision_hash, salt_hash);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 1, 1);
        assert!(simple_map::contains_key(&state.games, &0), 2);
        assert!(event::counter(&state.create_game_events) == 1, 3);
        assert!(event::counter(&state.submit_decision_events) == 1, 4);
        assert!(event::counter(&state.reveal_decision_events) == 0, 5);
        assert!(event::counter(&state.conclude_game_events) == 0, 6);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            8
        );
        assert!(
            guid::creator_address(event::guid(&state.submit_decision_events)) == resource_account_address,
            9
        );
        assert!(guid::creator_address(event::guid(&state.reveal_decision_events)) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            11
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            12
        );

        let game = simple_map::borrow(&state.games, &0);
        assert!(game.prize_pool_amount == prize_pool_amount, 13);
        assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

        assert!(game.player_one.player_address == player_one_address, 15);
        assert!(option::contains(&game.player_one.decision_hash, &decision_hash), 16);
        assert!(option::contains(&game.player_one.salt_hash, &salt_hash), 17);
        assert!(game.player_one.decision == DECISION_NOT_MADE, 18);

        assert!(game.player_two.player_address == player_two_address, 19);
        assert!(option::is_none(&game.player_two.decision_hash), 20);
        assert!(option::is_none(&game.player_two.salt_hash), 21);
        assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

        assert!(coin::balance<AptosCoin>(@overmind) == 0, 23);
        assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 24);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 25);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_submit_decision_state_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&account, game_id, decision_hash, salt_hash);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_submit_decision_game_does_not_exist() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_one, game_id, decision_hash, salt_hash);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_submit_decision_player_does_not_participate_in_the_game() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let another_player = account::create_account_for_test(@0xACE123);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&another_player, game_id, decision_hash, salt_hash);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_submit_decision_player_one_has_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_one, game_id, decision_hash, salt_hash);
        submit_decision(&player_one, game_id, decision_hash, salt_hash);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 8, location = Self)]
    fun test_submit_decision_player_two_has_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_two = account::create_account_for_test(@0xCAFE);
        let game_id = 0;
        let salt = b"saltsaltsalt";
        let decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut decision, salt);

        let decision_hash = hash::sha3_256(decision);
        let salt_hash = sha3_256(salt);
        submit_decision(&player_two, game_id, decision_hash, salt_hash);
        submit_decision(&player_two, game_id, decision_hash, salt_hash);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_split() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_SPLIT, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == prize_pool_amount / 2, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == prize_pool_amount / 2, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_player_one_steals() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_STEAL, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == prize_pool_amount, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_player_two_steals() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_SPLIT);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_SPLIT, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == 0, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == prize_pool_amount, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_reveal_decision_both_players_steal() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, 0, string::utf8(player_one_salt));

        let resource_account_address =
            account::create_resource_address(&@overmind, SEED);
        {
            let state = borrow_global<State>(@overmind);
            assert!(state.next_game_id == 1, 0);
            assert!(simple_map::length(&state.games) == 1, 1);
            assert!(simple_map::contains_key(&state.games, &0), 2);
            assert!(event::counter(&state.create_game_events) == 1, 3);
            assert!(event::counter(&state.submit_decision_events) == 2, 4);
            assert!(event::counter(&state.reveal_decision_events) == 1, 5);
            assert!(event::counter(&state.conclude_game_events) == 0, 6);
            assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 7);

            assert!(
                guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
                8
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.submit_decision_events)
                ) == resource_account_address,
                9
            );
            assert!(guid::creator_address(
                event::guid(&state.reveal_decision_events)
            ) == resource_account_address,
                10
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.conclude_game_events)
                ) == resource_account_address,
                11
            );
            assert!(
                guid::creator_address(
                    event::guid(&state.release_funds_after_expiration_events)
                ) == resource_account_address,
                12
            );

            let game = simple_map::borrow(&state.games, &0);
            assert!(game.prize_pool_amount == prize_pool_amount, 13);
            assert!(game.expiration_timestamp_in_seconds >= 3610 && game.expiration_timestamp_in_seconds <= 3611, 14);

            assert!(game.player_one.player_address == player_one_address, 15);
            assert!(option::contains(&game.player_one.decision_hash, &player_one_decision_hash), 16);
            assert!(option::contains(&game.player_one.salt_hash, &player_one_salt_hash), 17);
            assert!(game.player_one.decision == DECISION_STEAL, 18);

            assert!(game.player_two.player_address == player_two_address, 19);
            assert!(option::contains(&game.player_two.decision_hash, &player_two_decision_hash), 20);
            assert!(option::contains(&game.player_two.salt_hash, &player_two_salt_hash), 21);
            assert!(game.player_two.decision == DECISION_NOT_MADE, 22);

            assert!(coin::balance<AptosCoin>(resource_account_address) == prize_pool_amount, 23);
            assert!(coin::balance<AptosCoin>(@overmind) == 0, 24);
            assert!(coin::balance<AptosCoin>(player_one_address) == 0, 25);
            assert!(coin::balance<AptosCoin>(player_two_address) == 0, 26);

            assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 27);
        };

        reveal_decision(&player_two, 0, string::utf8(player_two_salt));

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 28);
        assert!(simple_map::length(&state.games) == 0, 29);
        assert!(event::counter(&state.create_game_events) == 1, 30);
        assert!(event::counter(&state.submit_decision_events) == 2, 31);
        assert!(event::counter(&state.reveal_decision_events) == 2, 32);
        assert!(event::counter(&state.conclude_game_events) == 1, 33);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 0, 34);

        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            35
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            36
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            37
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            38
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            39
        );

        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 40);
        assert!(coin::balance<AptosCoin>(@overmind) == prize_pool_amount, 41);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 42);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 43);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 44);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_reveal_decision_state_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&account, game_id, salt);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_reveal_decision_game_does_not_exist() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&player_one, game_id, salt);
    }

    #[test]
    #[expected_failure(abort_code = 4, location = Self)]
    fun test_reveal_decision_player_does_not_participate_in_the_game() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let another_player = account::create_account_for_test(@0xACE123);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&another_player, game_id, salt);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_reveal_decision_both_players_do_not_have_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let salt = string::utf8(b"saltsaltsalt");
        reveal_decision(&player_one, game_id, salt);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_reveal_decision_player_two_does_not_have_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);
        reveal_decision(&player_one, game_id, string::utf8(player_one_salt));

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 7, location = Self)]
    fun test_reveal_decision_player_one_does_not_have_a_decision_submitted() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_two = account::create_account_for_test(@0xCAFE);
        let game_id = 0;
        let player_two_salt = b"saltsaltsalt";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);
        reveal_decision(&player_two, game_id, string::utf8(player_two_salt));

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_release_funds_after_expiration_transfer_to_overmind() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        coin::register<AptosCoin>(&player_one);

        let player_two = account::create_account_for_test(@0xCAFE);
        coin::register<AptosCoin>(&player_two);

        let any_account = account::create_account_for_test(@0x75348574903);
        coin::register<AptosCoin>(&any_account);
        timestamp::update_global_time_for_test_secs(3612);
        release_funds_after_expiration(&any_account, 0);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 1, 2);
        assert!(event::counter(&state.submit_decision_events) == 0, 3);
        assert!(event::counter(&state.reveal_decision_events) == 0, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 1, 6);

        let resource_account_address = account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            8
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );

        assert!(coin::balance<AptosCoin>(@overmind) == prize_pool_amount, 12);
        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 13);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 14);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 15);
        assert!(coin::balance<AptosCoin>(signer::address_of(&any_account)) == 0, 16);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 17);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_release_funds_after_expiration_transfer_to_player_one() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_one, game_id, string::utf8(player_one_salt));

        let any_account = account::create_account_for_test(@0x75348574903);
        coin::register<AptosCoin>(&any_account);
        timestamp::update_global_time_for_test_secs(3612);
        release_funds_after_expiration(&any_account, game_id);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 1, 2);
        assert!(event::counter(&state.submit_decision_events) == 2, 3);
        assert!(event::counter(&state.reveal_decision_events) == 1, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 1, 6);

        let resource_account_address = account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            8
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );

        assert!(coin::balance<AptosCoin>(@overmind) == 0, 12);
        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 13);
        assert!(coin::balance<AptosCoin>(player_one_address) == prize_pool_amount, 14);
        assert!(coin::balance<AptosCoin>(player_two_address) == 0, 15);
        assert!(coin::balance<AptosCoin>(signer::address_of(&any_account)) == 0, 16);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 17);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_release_funds_after_expiration_transfer_to_player_two() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        let player_one_salt = b"saltsaltsalt";
        let player_one_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_one_decision, player_one_salt);

        let player_one_decision_hash = hash::sha3_256(player_one_decision);
        let player_one_salt_hash = sha3_256(player_one_salt);
        coin::register<AptosCoin>(&player_one);
        submit_decision(&player_one, game_id, player_one_decision_hash, player_one_salt_hash);

        let player_two = account::create_account_for_test(@0xCAFE);
        let player_two_salt = b"saltyyyy";
        let player_two_decision = bcs::to_bytes(&DECISION_STEAL);
        vector::append(&mut player_two_decision, player_two_salt);

        let player_two_decision_hash = hash::sha3_256(player_two_decision);
        let player_two_salt_hash = sha3_256(player_two_salt);
        coin::register<AptosCoin>(&player_two);
        submit_decision(&player_two, game_id, player_two_decision_hash, player_two_salt_hash);

        reveal_decision(&player_two, game_id, string::utf8(player_two_salt));

        let any_account = account::create_account_for_test(@0x75348574903);
        coin::register<AptosCoin>(&any_account);
        timestamp::update_global_time_for_test_secs(3612);
        release_funds_after_expiration(&any_account, game_id);

        let state = borrow_global<State>(@overmind);
        assert!(state.next_game_id == 1, 0);
        assert!(simple_map::length(&state.games) == 0, 1);
        assert!(event::counter(&state.create_game_events) == 1, 2);
        assert!(event::counter(&state.submit_decision_events) == 2, 3);
        assert!(event::counter(&state.reveal_decision_events) == 1, 4);
        assert!(event::counter(&state.conclude_game_events) == 0, 5);
        assert!(event::counter(&state.release_funds_after_expiration_events) == 1, 6);

        let resource_account_address = account::create_resource_address(&@overmind, SEED);
        assert!(
            guid::creator_address(event::guid(&state.create_game_events)) == resource_account_address,
            7
        );
        assert!(
            guid::creator_address(
                event::guid(&state.submit_decision_events)
            ) == resource_account_address,
            8
        );
        assert!(guid::creator_address(
            event::guid(&state.reveal_decision_events)
        ) == resource_account_address,
            9
        );
        assert!(
            guid::creator_address(
                event::guid(&state.conclude_game_events)
            ) == resource_account_address,
            10
        );
        assert!(
            guid::creator_address(
                event::guid(&state.release_funds_after_expiration_events)
            ) == resource_account_address,
            11
        );

        assert!(coin::balance<AptosCoin>(@overmind) == 0, 12);
        assert!(coin::balance<AptosCoin>(resource_account_address) == 0, 13);
        assert!(coin::balance<AptosCoin>(player_one_address) == 0, 14);
        assert!(coin::balance<AptosCoin>(player_two_address) == prize_pool_amount, 15);
        assert!(coin::balance<AptosCoin>(signer::address_of(&any_account)) == 0, 16);

        assert!(&state.cap == &account::create_test_signer_cap(resource_account_address), 17);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    #[expected_failure(abort_code = 0, location = Self)]
    fun test_release_funds_after_expiration_is_not_initialized() acquires State {
        let account = account::create_account_for_test(@0xACE);
        let game_id = 0;
        release_funds_after_expiration(&account, game_id);
    }

    #[test]
    #[expected_failure(abort_code = 3, location = Self)]
    fun test_release_funds_after_expiration_game_does_not_exist() acquires State {
        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        release_funds_after_expiration(&player_one, game_id);
    }

    #[test]
    #[expected_failure(abort_code = 6, location = Self)]
    fun test_release_funds_after_expiration_game_not_expired_yet() acquires State {
        let aptos_framework = account::create_account_for_test(@aptos_framework);
        timestamp::set_time_has_started_for_testing(&aptos_framework);
        let (burn_cap, mint_cap) =
            aptos_coin::initialize_for_test(&aptos_framework);

        let account = account::create_account_for_test(@overmind);
        init_module(&account);

        let prize_pool_amount = 10 * 10 ^ 8;
        let player_one_address = @0xACE;
        let player_two_address = @0xCAFE;
        coin::register<AptosCoin>(&account);
        aptos_coin::mint(&aptos_framework, @overmind, prize_pool_amount);
        timestamp::update_global_time_for_test_secs(10);
        create_game(&account, prize_pool_amount, player_one_address, player_two_address);

        let player_one = account::create_account_for_test(@0xACE);
        let game_id = 0;
        release_funds_after_expiration(&player_one, game_id);

        coin::destroy_burn_cap(burn_cap);
        coin::destroy_mint_cap(mint_cap);
    }

    #[test]
    fun test_make_decision() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::some(hash::sha3_256(salt)),
            decision_hash: option::some(hash::sha3_256(decision_bytes)),
            decision: DECISION_NOT_MADE
        };

        let decision = make_decision(&mut player_data, &string::utf8(salt));
        assert!(decision == DECISION_SPLIT, 0);
        assert!(player_data.player_address == @0x123123123, 1);
        assert!(option::contains(&player_data.salt_hash, &hash::sha3_256(salt)), 2);
        assert!(option::contains(&player_data.decision_hash, &hash::sha3_256(decision_bytes)), 3);
        assert!(player_data.decision == DECISION_SPLIT, 4);
    }

    #[test]
    #[expected_failure(abort_code = 0x40001, location = std::option)]
    fun test_make_decision_salt_hash_is_none() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::none(),
            decision_hash: option::some(hash::sha3_256(decision_bytes)),
            decision: DECISION_NOT_MADE
        };

        make_decision(&mut player_data, &string::utf8(salt));
    }

    #[test]
    #[expected_failure(abort_code = 5, location = Self)]
    fun test_make_decision_incorrect_hash_value() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::some(hash::sha3_256(b"salt")),
            decision_hash: option::some(hash::sha3_256(decision_bytes)),
            decision: DECISION_NOT_MADE
        };

        make_decision(&mut player_data, &string::utf8(salt));
    }

    #[test]
    #[expected_failure(abort_code = 0x40001, location = std::option)]
    fun test_make_decision_decision_hash_is_none() {
        let decision_bytes = bcs::to_bytes(&DECISION_SPLIT);
        let salt = b"saltyyyyyy";
        vector::append(&mut decision_bytes, salt);

        let player_data = PlayerData {
            player_address: @0x123123123,
            salt_hash: option::some(hash::sha3_256(salt)),
            decision_hash: option::none(),
            decision: DECISION_NOT_MADE
        };

        make_decision(&mut player_data, &string::utf8(salt));
    }

    #[test]
    fun test_get_next_game_id() {
        let next_game_id_counter = 7328723;
        let next_game_id = get_next_game_id(&mut next_game_id_counter);

        assert!(next_game_id_counter == 7328724, 0);
        assert!(next_game_id == 7328723, 1);
    }
}