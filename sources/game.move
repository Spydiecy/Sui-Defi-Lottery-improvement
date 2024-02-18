#[allow(lint(self_transfer))]
module lottery::game {
    use lottery::drand_lib::{derive_randomness, verify_drand_signature, safe_selection};
    use sui::object::{Self, UID, ID};
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::sui::SUI;
    use sui::clock::{Self, Clock};
    use std::option::{Self, Option};
    use std::vector;

    const EPaymentTooLow : u64 = 0;
    const EWrongLottery : u64 = 1;
    const ELotteryEnded: u64 = 2;
    const ELotteryNotEnded: u64 = 4;
    const ELotteryCompleted: u64 = 5;

    const ACTIVE : u64 = 0;
    const ENDED: u64 = 1;
    const COMPLETED: u64 = 2;

    struct Lottery has key {
        id: UID,
        round: u64,
        endTime: u64,
        noOfTickets: u64,
        noOfPlayers: u32,
        winner: Option<address>,
        winningTicket: Option<u64>,
        ticketPrice: u64,
        reward: Balance<SUI>,
        status: u64,
    }

    struct PlayerRecord has key, store {
        id: UID,
        lotteryId: ID,
        tickets: vector<u64>,
    }

    // Starts a new lottery
    public fun startLottery(round: u64, ticketPrice: u64, lotteryDuration: u64, clock: &Clock, ctx: &mut TxContext) {
        let endTime = (lotteryDuration * 60 * 1000) + clock::timestamp_ms(clock);

        let lottery = Lottery {
            id: object::new(ctx),
            round,
            endTime,
            noOfTickets: 0,
            noOfPlayers: 0,
            winner: option::none(),
            winningTicket: option::none(),
            ticketPrice,
            reward: balance::zero(),
            status: ACTIVE, 
        };

        transfer::share_object(lottery);
    }

    // Creates a player record for a lottery
    public fun createPlayerRecord(lottery: &mut Lottery, ctx: &mut TxContext) {
        let lotteryId = object::uid_to_inner(&lottery.id);

        let player = PlayerRecord {
            id: object::new(ctx),
            lotteryId,
            tickets: vector::empty(),
        };

        lottery.noOfPlayers = lottery.noOfPlayers + 1;

        transfer::public_transfer(player, tx_context::sender(ctx));
    }

    // Buys a ticket for a lottery
    public fun buyTicket(lottery: &mut Lottery, playerRecord: &mut PlayerRecord, noOfTickets: u64, amount: Coin<SUI>, clock: &Clock ): u64 {
        assert!(object::id(lottery) == playerRecord.lotteryId, EWrongLottery);
        assert!(lottery.endTime > clock::timestamp_ms(clock), ELotteryEnded);
        assert!(lottery.status == ACTIVE, ELotteryEnded);

        let amountRequired = lottery.ticketPrice * noOfTickets;
        assert!(coin::value(&amount) >= amountRequired, EPaymentTooLow);

        let coin_balance = coin::into_balance(amount);
        balance::join(&mut lottery.reward, coin_balance);

        let oldTicketsCount = lottery.noOfTickets;
        let newTicketId = oldTicketsCount;
        let newTotal = oldTicketsCount + noOfTickets;
        while (newTicketId < newTotal) {
            vector::push_back(&mut playerRecord.tickets, newTicketId);
            newTicketId = newTicketId + 1;
        };

        vector::length(& playerRecord.tickets)
    }

    // Ends a lottery
    public fun endLottery(lottery: &mut Lottery, clock: &Clock, drand_sig: vector<u8>){
        assert!(lottery.endTime < clock::timestamp_ms(clock), ELotteryNotEnded);
        assert!(lottery.status == ACTIVE, ELotteryEnded);

        verify_drand_signature(drand_sig, lottery.round);

        let digest = derive_randomness(drand_sig);

        lottery.winningTicket = option::some(safe_selection(lottery.noOfTickets, &digest));

        lottery.status = ENDED;
    }

    // Checks if a player is the winner of a lottery
    public fun checkIfWinner(lottery: &mut Lottery, player: PlayerRecord, ctx: &mut TxContext): bool {
        let PlayerRecord {id, lotteryId, tickets } = player;
        
        assert!(object::id(lottery) == lotteryId, EWrongLottery);
        assert!(lottery.status!= COMPLETED, ELotteryCompleted);
        assert!(lottery.status == ENDED, ELotteryNotEnded);

        let winningTicket = option::extract(&mut lottery.winningTicket);

        let isWinner = vector::contains(&tickets, &winningTicket);   

        if (isWinner){
            lottery.winner = option::some(tx_context::sender(ctx));

            let amount = balance::value(&lottery.reward);

            let reward = coin::take(&mut lottery.reward, amount, ctx);
           
            transfer::public_transfer(reward, tx_context::sender(ctx));

            lottery.status = COMPLETED; 
        };
        
        object::delete(id);

        isWinner
    }
}
