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

    public fun startLottery(round: u64, ticketPrice: u64, lotteryDuration: u64, clock: &Clock, ctx: &mut TxContext) {
        // lotteryDuration is passed in minutes,
        let endTime = (lotteryDuration * 60 * 1000) + clock::timestamp_ms(clock);

        // create Lottery
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

        // make lottery accessible by everyone
        transfer::share_object(lottery);
    }

    public fun createPlayerRecord(lottery: &mut Lottery, ctx: &mut TxContext) {
        // get lottery id
        let lotteryId = object::uid_to_inner(&lottery.id);

        // create player record for lottery ID
        let player = PlayerRecord {
            id: object::new(ctx),
            lotteryId,
            tickets: vector::empty(),
        };

        lottery.noOfPlayers = lottery.noOfPlayers + 1;

        transfer::public_transfer(player, tx_context::sender(ctx));
    }

    // Anyone can buyticket after getting a playerRecord
    public fun buyTicket(lottery: &mut Lottery, playerRecord: &mut PlayerRecord, noOfTickets: u64, amount: Coin<SUI>, clock: &Clock ): u64 {
        // check if user is calling from right lottery
        assert!(object::id(lottery) == playerRecord.lotteryId, EWrongLottery);

        // check that lottery has not ended
        assert!(lottery.endTime > clock::timestamp_ms(clock), ELotteryEnded);

        // check that lottery state is stil 0
        assert!(lottery.status == ACTIVE, ELotteryEnded);

        // calculate the total amount to be paid
        let amountRequired = lottery.ticketPrice * noOfTickets;

        // check that coin supplied is equal to the total amount required
        assert!(coin::value(&amount) >= amountRequired, EPaymentTooLow);

        // add the amount to the lottery's balance
        let coin_balance = coin::into_balance(amount);
        balance::join(&mut lottery.reward, coin_balance);

        // increment no of tickets bought and update players ticket record
        let oldTicketsCount = lottery.noOfTickets;
        let newTicketId = oldTicketsCount;
        let newTotal = oldTicketsCount + noOfTickets;
        while (newTicketId < newTotal) {
            vector::push_back(&mut playerRecord.tickets, newTicketId);
            newTicketId = newTicketId + 1;
        };

        // return player ticket length
        vector::length(& playerRecord.tickets)
    }

    // Anyone can end the lottery by providing the randomness of round.
    // randomness signature can be gotten from https://drand.cloudflare.com/52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971/public/<round>
    public fun endLottery(lottery: &mut Lottery, clock: &Clock, drand_sig: vector<u8>){
        // check that lottery has ended
        assert!(lottery.endTime < clock::timestamp_ms(clock), ELotteryNotEnded);

        // check that lottery state is stil 0
        assert!(lottery.status == ACTIVE, ELotteryEnded);

        verify_drand_signature(drand_sig, lottery.round);

        // The randomness is derived from drand_sig by passing it through sha2_256 to make it uniform.
        let digest = derive_randomness(drand_sig);

        lottery.winningTicket = option::some(safe_selection(lottery.noOfTickets, &digest));

        lottery.status = ENDED;
    }

    // Lottery Players can check if they won
    public fun checkIfWinner(lottery: &mut Lottery, player: PlayerRecord, ctx: &mut TxContext): bool {
        let PlayerRecord {id, lotteryId, tickets } = player;
        
        // check if user is calling from right lottery
        assert!(object::id(lottery) == lotteryId, EWrongLottery);

        // check that lottery state is not completed
        assert!(lottery.status!= COMPLETED, ELotteryCompleted);

        // check that lottery state is ended
        assert!(lottery.status == ENDED, ELotteryNotEnded);

        // get winning ticket
        let winningTicket = option::extract(&mut lottery.winningTicket);

        // check if winning ticket exists in lottery tickets
        let isWinner = vector::contains(&tickets, &winningTicket);   

        if (isWinner){
            // set user as winner
            lottery.winner = option::some(tx_context::sender(ctx));

            // get the reward
            let amount = balance::value(&lottery.reward);

            // wrap reward with coin
            let reward = coin::take(&mut lottery.reward, amount, ctx);
           
            transfer::public_transfer(reward, tx_context::sender(ctx));

            lottery.status = COMPLETED; 
        };
        
        // delete player record
        object::delete(id);

        isWinner
    }
}