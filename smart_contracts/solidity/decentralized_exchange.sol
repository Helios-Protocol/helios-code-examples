pragma solidity ^100.5.14;

import "./helpers/smart_contract_chain.sol";
import "./helpers/safe_math.sol";
import "./helpers/execute_on_send.sol";
import "./helpers/ownable.sol";
import "./helpers/order_book.sol";


contract Token {
    function getBalance() public view returns (uint256);
    function transactionReceived(bytes32 receipt_identifier) public view returns (bool);
}

// Minting has to occur on smart contract chain because that is where the owner variable is stored.
contract DecentralizedExchange is Ownable, ExecuteOnSend, OrderBook{
    using SafeMath for uint256;

    struct PendingDepositInfo {
        uint256 amount;
        bytes32 receipt_identifier;
    }

    mapping(address => mapping (address => PendingDepositInfo[])) public pending_deposits; // wallet address -> token contract (0 for HLS) -> list of pending deposits for that contract.
    mapping(address => mapping (address => uint256)) public tokens; //mapping of token addresses to mapping of account balances (token contract = 0 means HLS)


    uint256 deposit_nonce;

    function depositTokens(address exchange_deposit_address, address token_contract_address, uint256 amount, uint256 this_deposit_nonce) public requireExecuteOnSendTx{
        if(is_send()){
            // Lets make sure they have enough balance on this chain. They could potentially spend the balance before
            // the transaction is sent, resulting in an error, but that is why we use a receipt identifier to know
            // if it was received or not.
            uint256 token_balance_on_this_chain = Token(token_contract_address).getBalance();
            require(
                amount <= token_balance_on_this_chain,
                "This chain doesn't have enough tokens for the deposit"
            );
            require(
                this_deposit_nonce == deposit_nonce,
                "Your deposit nonce is incorrect."
            );
            require(
                token_contract_address != address(0),
                "To deposit HLS, use depositHLS function"
            );


            bytes32 receipt_identifier = getNewReceiptIdentifier(this_deposit_nonce);

            // Send the transaction
            bytes4 sig = bytes4(keccak256("transfer(uint256,bytes32)")); //Function signature
            assembly {
                let x := mload(0x40)   //Find empty storage location using "free memory pointer"
                mstore(x,sig) //Place signature at beginning of empty storage (4 bytes)
                mstore(add(x,0x04),amount) //Place first argument directly next to signature (32 byte int256)
                mstore(add(x,0x24),receipt_identifier) //Place second argument next to it (32 byte bytes32)

                let success := surrogatecall(100000, //100k gas
                                            token_contract_address, //Delegated token contract address
                                            0,       //Value
                                            1,      //Execute on send?
                                            exchange_deposit_address,   //To addr
                                            x,    //Inputs are stored at location x
                                            0x44 //Inputs are 4 + 32 + 32 = 68 bytes long
                                            )
            }
            deposit_nonce = deposit_nonce + 1;

        }else{

            // Here lets check if it was already received, if so lets just add it to the balance
            bytes32 receipt_identifier = getNewReceiptIdentifier(this_deposit_nonce);

            bool is_transaction_received = Token(token_contract_address).transactionReceived(receipt_identifier);
            if(is_transaction_received){
                // it has already been received
                tokens[msg.sender][token_contract_address].add(amount);
            }else{
                // it has not been received
                pending_deposits[msg.sender][token_contract_address].push(
                    PendingDepositInfo({
                        amount: amount,
                        receipt_identifier: receipt_identifier
                    })
                );
            }

        }
    }

    function withdrawTokens(address token_contract_address, uint256 amount) public {
        require(token_contract_address != address(0));
        require(tokens[msg.sender][token_contract_address] >= amount);
        tokens[msg.sender][token_contract_address] = tokens[msg.sender][token_contract_address].sub(amount);

        // Send the transaction
        bytes4 sig = bytes4(keccak256("transfer(uint256)")); //Function signature
        address to = msg.sender;
        assembly {
            let x := mload(0x40)   //Find empty storage location using "free memory pointer"
            mstore(x,sig) //Place signature at beginning of empty storage (4 bytes)
            mstore(add(x,0x04),amount) //Place first argument directly next to signature (32 byte int256)

            let success := surrogatecall(100000, //100k gas
                                        token_contract_address, //Delegated token contract address
                                        0,       //Value
                                        1,      //Execute on send?
                                        to,   //To addr
                                        x,    //Inputs are stored at location x
                                        0x24 //Inputs are 4 + 32 = 36 bytes long
                                        )
        }

    }
    function getNewReceiptIdentifier(uint256 this_deposit_nonce) private returns (bytes32){
        bytes32 receipt_identifier = keccak256(abi.encodePacked(this_deposit_nonce, msg.sender));
        return receipt_identifier;
    }

    function processPendingDeposits(address wallet_address, address token_contract_address) public{
        uint i = 0;
        while(i < pending_deposits[wallet_address][token_contract_address].length){

            bool is_transaction_received = Token(token_contract_address).transactionReceived(pending_deposits[wallet_address][token_contract_address][i].receipt_identifier);
            if(is_transaction_received){
                // it has already been received
                // add to the token balance
                tokens[wallet_address][token_contract_address] = tokens[wallet_address][token_contract_address].add(pending_deposits[wallet_address][token_contract_address][i].amount);

                //delete the pending deposit element and shift the array
                if(i == pending_deposits[wallet_address][token_contract_address].length - 1){
                    // it is the last element. just delete
                    delete pending_deposits[wallet_address][token_contract_address][i];
                }else{
                    // replace the element with the one at the end of the list
                    pending_deposits[wallet_address][token_contract_address][i] = pending_deposits[wallet_address][token_contract_address][pending_deposits[wallet_address][token_contract_address].length - 1];

                    // delete the element at the end
                    delete pending_deposits[wallet_address][token_contract_address][pending_deposits[wallet_address][token_contract_address].length - 1];
                }
            }else{
                // only increment the counter if we didnt just shift the array
                i = i + 1;
            }
        }
    }

    // function to deposit HLS
    // This could fail if they don't give enough gas. Need to require a certain amount of gas
    function depositHLS() public payable {
        tokens[msg.sender][address(0)] = tokens[msg.sender][address(0)].add(msg.value);
    }

    function withdrawHLS(uint amount) public {
        require(tokens[msg.sender][address(0)] >= amount);
        tokens[msg.sender][address(0)] = tokens[msg.sender][address(0)].sub(amount);
        msg.sender.transfer(amount);
    }

    //
    // trading
    //
    function trade(address sell_token, address buy_token, uint256 amount, uint256 price) public{
        require(
            (tokens[msg.sender][sell_token] - amount_in_orders[msg.sender][sell_token]) >= amount,
            "Not enough tokens in your account to place this order"
        );
        require(
            amount != 0,
            "Cannot trade for 0 amount"
        );
        require(
            price != 0,
            "Cannot trade for 0 price"
        );
        require(
            price <= (1 ether)*(1 ether),
            "Price is higher than maximum allowed price"
        );
        uint256 amount_remaining_in_sell_token = amount;

        // first lets see if there is anyone to match with.
        uint256 inverse_price = getInversePrice(price);
        Order memory top_sell_order = orders[buy_token][sell_token][head[buy_token][sell_token]];
        while(top_sell_order.price <= inverse_price && top_sell_order.price != 0){
            uint256 amount_in_buy_token_at_existing_order_price = amount_remaining_in_sell_token.mul(getInversePrice(top_sell_order.price)).div(1 ether);

            if(amount_in_buy_token_at_existing_order_price < top_sell_order.amount_remaining){
                // here we do a partial order and subtract from order remaining


                // trade the tokens
                tokens[msg.sender][sell_token] = tokens[msg.sender][sell_token].sub(amount_remaining_in_sell_token);
                tokens[msg.sender][buy_token] = tokens[msg.sender][buy_token].add(amount_in_buy_token_at_existing_order_price);

                tokens[top_sell_order.user][sell_token] = tokens[top_sell_order.user][sell_token].add(amount_remaining_in_sell_token);
                tokens[top_sell_order.user][buy_token] = tokens[top_sell_order.user][buy_token].sub(amount_in_buy_token_at_existing_order_price);

                // modify the order book
                // buy and sell tokens are reversed here because we are selling into the opposite order book
                subtractAmountFromOrder(buy_token, sell_token, head[buy_token][sell_token], amount_in_buy_token_at_existing_order_price);
                // the entire order is complete. end the loop
                return;
            }else{

                // here we take the whole order and delete it
                uint256 amount_in_sell_token_existing_order_will_buy = top_sell_order.price*top_sell_order.amount_remaining/(1 ether);

                // trade the tokens
                tokens[msg.sender][sell_token] = tokens[msg.sender][sell_token].sub(amount_in_sell_token_existing_order_will_buy);
                tokens[msg.sender][buy_token] = tokens[msg.sender][buy_token].add(top_sell_order.amount_remaining);



                tokens[top_sell_order.user][sell_token] = tokens[top_sell_order.user][sell_token].add(amount_in_sell_token_existing_order_will_buy);
                tokens[top_sell_order.user][buy_token] = tokens[top_sell_order.user][buy_token].sub(top_sell_order.amount_remaining);


                // modify the order book
                deleteOrder(buy_token, sell_token, head[buy_token][sell_token]);

                // modify amount_remaining_in_sell_token
                amount_remaining_in_sell_token = amount_remaining_in_sell_token.sub(amount_in_sell_token_existing_order_will_buy);

            }
            // redefine top_sell_order
            // redefine amount remaining
            top_sell_order = orders[buy_token][sell_token][head[buy_token][sell_token]];

        }

        // any amount left after matching is sent as a new order
        addOrder(sell_token, buy_token, amount_remaining_in_sell_token, price);

    }

    function getInversePrice(uint256 price) public returns (uint256){
        return uint256(1 ether).mul(1 ether).div(price);
    }

    constructor() public {

    }

    // if someone deposits HLS, call the deposit command.
    // This could fail if they don't give enough gas. Need to require a certain amount of gas
    function() external payable{
        depositHLS();
    }
}