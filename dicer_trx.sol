pragma solidity ^0.6.0;

contract Dicer {
    uint constant MAX_BET_TYPE = 36;
    uint constant GAME_FEE = 1;
    uint constant MIN_AMOUNT = 10 trx;
    uint constant GAME_CREATE_LIMIT = 0.1 trx;

    uint public GAME_COUNT = 0;
    uint public LOCK_BALANCE = 0;

    struct Game {
        address payable creator;
        uint min_amount;
        uint max_amount;
        uint game_fee;
        uint prize_fee;
        uint amount;
        uint amount_locked;
        uint lucky_num;
        uint total_prize;
        uint bet_count;
        int8 status;
    }

    struct Bet {
        address payable player;
        bytes32 game_id;
        uint amount;
        uint bet_type;
        uint bet_data;
        bytes32 seed;
        bytes32 bet_result;
        int8 status;
    }

    mapping(bytes32 => Game) public games;
    mapping(bytes32 => Bet) public bets;


    address payable owner;
    modifier onlyOwner() {
        require(msg.sender == owner);
        _;
    }
    bool public isOpen = true;

    event log_pay(address addr, uint amount, bool result);
    event log_prize(address addr, uint amount);

    constructor () public {
        owner = msg.sender;
    }
    

    function create(bytes32 game_id,uint min_amount, uint max_amount, uint game_fee, uint prize_fee, uint lucky_num) public payable {
        require(isOpen, "the game is closed");
        require(min_amount >= MIN_AMOUNT, "error min_amount");
        require(max_amount > min_amount, "error max_amount");
        require(game_fee >= GAME_FEE, "error game_fee");
        

        Game storage game = games[game_id];
        if(game.creator!=address(0) && game.creator!=msg.sender){
            revert("error game");
        }
        if(game.amount==0 && game.bet_count==0){
            require(msg.value >= GAME_CREATE_LIMIT, "not enough amount");
            GAME_COUNT += 1;
        }
        game.creator = msg.sender;
        game.min_amount = min_amount;
        game.max_amount = max_amount;
        game.game_fee = game_fee;
        game.prize_fee = prize_fee;
        game.status = 1;
        game.amount += msg.value;
        if(game.amount_locked==0){
            game.lucky_num = lucky_num;
        }
        LOCK_BALANCE += msg.value;
    }

    function placeBet(bytes32 game_id, bytes32 commit, uint bet_data, uint bet_type) public payable {
        require(bet_type > 1 && bet_type <= MAX_BET_TYPE,"Bet_type should be within range.");

        Game storage game = games[game_id];
        require(game.status == 1, "Error game status");
        uint amount = msg.value;
        require(amount >= game.min_amount && amount <= game.max_amount, "Amount should be within range.");

        Bet storage bet = bets[commit];
        require(bet.player == address(0), "Error bet");
        uint select_count = getSelectCount(bet_data);
        uint locked_amount = msg.value * bet_type / select_count;
        require(locked_amount <= game.amount - game.amount_locked, "Game error");

        bet.game_id = game_id;
        bet.player = msg.sender;
        bet.bet_data = bet_data;
        bet.bet_type = bet_type;
        bet.amount = amount;
        bet.status = 0;
        bet.seed = keccak256(abi.encodePacked(commit, block.difficulty, block.timestamp));

        game.amount += bet.amount;
        game.amount_locked += locked_amount;
        game.bet_count += 1;
        LOCK_BALANCE += msg.value;
    }

    function settleBet(bytes32 reveal) public payable {

        bytes32 bet_id = keccak256(abi.encodePacked(reveal));
        Bet storage bet = bets[bet_id];
        require(bet.player != address(0), "error bet");
        require(bet.status == 0, "error bet status");

        bet.bet_result = keccak256(abi.encodePacked(bet.seed, reveal));

        doPrize(bet);
    }

    function doPrize(Bet storage bet) private {
        if (bet.status != 0 || bet.bet_result == 0) {
            revert();
        }

        uint bet_result = uint(bet.bet_result);
        uint dice = bet_result % bet.bet_type;
        if ((2 ** dice) & bet.bet_data != 0) {
            bet.status = 2;
        } else {
            bet.status = 1;
        }
        
        Game storage game = games[bet.game_id];
        uint select_count = getSelectCount(bet.bet_data);
        uint locked_amount = bet.amount * bet.bet_type / select_count;
        if(game.amount_locked >= locked_amount){
            game.amount_locked -= locked_amount;
        }else{
            game.amount_locked = 0;
        }
        uint sys_fee = bet.amount * GAME_FEE / 100;
        uint game_fee = bet.amount * game.game_fee / 100;
        
        game.amount -= sys_fee;
        uint lock_balance = sys_fee;

        uint win_amount = 0;
        if (bet.status == 2) {
            win_amount = (bet.amount - game.prize_fee - game_fee) * bet.bet_type / select_count;
            game.amount -= win_amount;
            lock_balance -= win_amount;
        }

        game.amount -= game.prize_fee;

        game.total_prize += game.prize_fee;
        if (game.total_prize > 0 && bet_result / bet.bet_type % game.lucky_num == 0) {
            emit log_prize(bet.player,game.total_prize);
            win_amount += game.total_prize;
            lock_balance -= game.total_prize;
            game.total_prize = 0;
        }

        LOCK_BALANCE -= lock_balance;

        if (win_amount > 0) {
            if(safeSend(bet.player, win_amount)){
                bet.status += 2;
            }
        }
    }

    function recharge(bytes32 game_id) public payable {
        Game storage game = games[game_id];
        require(msg.value > 0, "");
        game.amount += msg.value;
        LOCK_BALANCE += msg.value;
    }

    function withdraw(bytes32 game_id, uint amount) public payable{
        Game storage game = games[game_id];
        require(game.creator == msg.sender, "no access");
        require(game.amount - game.amount_locked >= amount, "balance is not enough");
        game.amount -= amount;
        LOCK_BALANCE -= amount;

        uint sys_fee = amount * GAME_FEE / 100;
        safeSend(msg.sender, amount - sys_fee);
    }

    function changeCreator(bytes32 game_id, address payable new_creator) public {
        Game storage game = games[game_id];
        require(game.creator == msg.sender, "no access");
        require(new_creator != address(0), "error address");

        game.creator = new_creator;
    }

    function setStatus(bytes32 game_id, int8 status) public {
        if (status != 1) {
            status = 0;
        }
        Game storage game = games[game_id];
        require(game.creator == msg.sender, "");
        require(game.status != status, "");
        game.status = status;
        if (game.status == 1) {
            GAME_COUNT += 1;
        } else {
            if(GAME_COUNT>0){
                GAME_COUNT -= 1;
            }
        }
    }

    function getSelectCount(uint bet_data) private returns(uint) {
        uint size = 0;
        while (bet_data > 0) {
            if (bet_data % 2 == 1) {
                size += 1;
            }
            bet_data /= 2;
        }
        return size;
    }


    function stop() public onlyOwner {
        require(GAME_COUNT == 0, "");
        isOpen = false;
    }

    function start() public onlyOwner {
        isOpen = true;
    }

    function safeSend(address payable addr, uint value) private returns(bool) {
        if (addr == address(0) || value == 0 || address(this).balance < value) {
            emit log_pay(addr, value, false);
            return false;
        }
        
        bool res = addr.send(value);
        emit log_pay(addr, value, res);
        return res;
    }

    function changeOwner(address payable new_owner) public onlyOwner {
        require(new_owner != address(0x0), "error address");
        owner = new_owner;
    }

    function profit(address payable addr,uint value) public onlyOwner {
        //require(value <= Balance, "");
        require(value <= address(this).balance, "balance is not enough");

        safeSend(addr, value);
    }
}