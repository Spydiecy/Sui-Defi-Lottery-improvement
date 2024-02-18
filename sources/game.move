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
    use std::vec::Vec;

    const E_PAYMENT_TOO_LOW : u64 = 0;
    const E_WRONG_LOTTERY : u64 = 1;
    const E_LOTTERY_ENDED: u64 = 2;
    const E_LOTTERY_NOT_ENDED: u64 = 4;
    const E_LOTTERY_COMPLETED: u64 = 5;

    enum LotteryStatus {
        Active,
        Ended,
        Completed,
    }

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
        status: LotteryStatus,
    }

    struct PlayerRecord has key, store {
        id: UID,
        lotteryId: ID,
        tickets: Vec<u64>,
    }

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
            status: LotteryStatus::Active, 
        };

        transfer::share_object(lottery);
    }

    public fun createPlayerRecord(lottery: &mut Lottery, ctx: &mut TxContext) {
        let lotteryId = object::uid_to_inner(&lottery.id);

        let player = PlayerRecord {
            id: object::new(ctx),
            lotteryId,
            tickets: Vec::new(),
        };

        lottery.noOfPlayers = lottery.noOfPlayers + 1;

        transfer::public_transfer(player, tx_context::sender(ctx));
    }

    public fun buyTicket(lottery: &mut Lottery, playerRecord: &mut PlayerRecord, noOfTickets: u64, amount: Coin<SUI>, clock: &Clock ): u64 {
        assert!(object::id(lottery) == playerRecord.lotteryId, E_WRONG_LOTTERY);
        assert!(lottery.endTime > clock::timestamp_ms(clock), E_LOTTERY_ENDED);
        assert!(lottery.status == LotteryStatus::Active, E_LOTTERY_ENDED);

        let amountRequired = lottery.ticketPrice * noOfTickets;
        assert!(coin::value(&amount) >= amountRequired, E_PAYMENT_TOO_LOW);

        let coin_balance = coin::into_balance(amount);
        balance::join(&mut lottery.reward, coin_balance);

        let oldTicketsCount = lottery.noOfTickets;
        let newTicketId = oldTicketsCount;
        let newTotal = oldTicketsCount + noOfTickets;
        while (newTicketId < newTotal) {
            playerRecord.tickets.push(newTicketId);
            newTicketId = newTicketId + 1;
        };

        playerRecord.tickets.len()
    }

    public fun endLottery(lottery: &mut Lottery, clock: &Clock, drand_sig: Vec<u8>){
        assert!(lottery.endTime < clock::timestamp_ms(clock), E_LOTTERY_NOT_ENDED);
        assert!(lottery.status == LotteryStatus::Active, E_LOTTERY_ENDED);

        verify_drand_signature(drand_sig, lottery.round);

        let digest = derive_randomness(drand_sig);

        lottery.winningTicket = option::some(safe_selection(lottery.noOfTickets, &digest));

        lottery.status = LotteryStatus::Ended;
    }

    public fun checkIfWinner(lottery: &mut Lottery, player: PlayerRecord, ctx: &mut TxContext): bool {
        let PlayerRecord {id, lotteryId, tickets } = player;
        
        assert!(object::id(lottery) == lotteryId, E_WRONG_LOTTERY);
        assert!(lottery.status!= LotteryStatus::Completed, E_LOTTERY_COMPLETED);
        assert!(lottery.status == LotteryStatus::Ended, E_LOTTERY_NOT_ENDED);

        let winningTicket = option::extract(&mut lottery.winningTicket);

        let isWinner = tickets.contains(&winningTicket);   

        if (isWinner){
            lottery.winner = option::some(tx_context::sender(ctx));

            let amount = balance::value(&lottery.reward);

            let reward = coin::take(&mut lottery.reward, amount, ctx);
           
            transfer::public_transfer(reward, tx_context::sender(ctx));

            lottery.status = LotteryStatus::Completed; 
        };
        
        object::delete(id);

        isWinner
    }
}
