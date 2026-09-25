import "@stdlib/ownable";
import "@stdlib/deploy";

const MAX_SUPPLY: Int = 1000000000000000000;
const GENESIS_MINT_TAG: Int = 0x474d494e;

message(0x0f8a7ea5) JettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(0x178d4519) JettonTransferInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    from: Address;
    responseDestination: Address;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

message(0x7362d09c) JettonNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    forwardPayload: Slice as remaining;
}

message(0xd53276db) JettonExcesses {
    queryId: Int as uint64;
}

message MintGenesis {
    queryId: Int as uint64;
    receiver: Address;
}

message RequestTokenWalletBinding {
    owner: Address;
}

message ConfirmTokenWalletBinding {
    wallet: Address;
}

message(0x595f07bc) JettonBurn {
    queryId: Int as uint64;
    amount: Int as coins;
    responseDestination: Address;
    customPayload: Cell?;
}
message(0x7bdd97de) JettonBurnNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address;
}

struct JettonWalletData {
    balance: Int as coins;
    owner: Address;
    master: Address;
    code: Cell;
}

struct JettonData {
    totalSupply: Int as coins;
    mintable: Bool;
    owner: Address;
    content: Cell;
    walletCode: Cell;
}

contract GameTokenWallet {
    balance: Int as coins;
    owner: Address;
    master: Address;

    init(owner: Address, master: Address) {
        self.balance = 0;
        self.owner = owner;
        self.master = master;
    }

    receive(msg: JettonTransfer) {
        require(sender() == self.owner, "not owner");
        self.balance -= msg.amount;
        require(self.balance >= 0, "insufficient balance");

        let initState = initOf GameTokenWallet(msg.destination, self.master);
        send(SendParameters {
            to: contractAddress(initState),
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonTransferInternal {
                queryId: msg.queryId,
                amount: msg.amount,
                from: self.owner,
                responseDestination: msg.responseDestination,
                forwardTonAmount: msg.forwardTonAmount,
                forwardPayload: msg.forwardPayload,
            }.toCell(),
            code: initState.code,
            data: initState.data,
        });
    }

    receive(msg: JettonTransferInternal) {
        if (sender() != self.master) {
            let expected = contractAddress(initOf GameTokenWallet(msg.from, self.master));
            require(sender() == expected, "not a valid wallet");
        }

        require(context().value >= msg.forwardTonAmount + ton("0.01"), "insufficient value for forward");
        self.balance += msg.amount;

        if (msg.forwardTonAmount > 0) {
            send(SendParameters {
                to: self.owner,
                value: msg.forwardTonAmount,
                mode: SendPayGasSeparately,
                bounce: false,
                body: JettonNotification {
                    queryId: msg.queryId,
                    amount: msg.amount,
                    sender: msg.from,
                    forwardPayload: msg.forwardPayload,
                }.toCell(),
            });
        }
        send(SendParameters {
            to: msg.responseDestination,
            value: 0,
            mode: SendRemainingValue + SendIgnoreErrors,
            bounce: false,
            body: JettonExcesses { queryId: msg.queryId }.toCell(),
        });
    }

    receive(msg: JettonBurn) {
        require(sender() == self.owner, "not owner");
        self.balance -= msg.amount;
        require(self.balance >= 0, "insufficient balance");
        send(SendParameters {
            to: self.master,
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonBurnNotification {
                queryId: msg.queryId,
                amount: msg.amount,
                sender: self.owner,
                responseDestination: msg.responseDestination,
            }.toCell(),
        });
    }

    bounced(src: Slice) {
        let op = src.loadUint(32);
        if (op == 0x178d4519 || op == 0x7bdd97de) {
            src.loadUint(64);
            self.balance += src.loadCoins();
        }
    }

    get fun get_wallet_data(): JettonWalletData {
        return JettonWalletData {
            balance: self.balance,
            owner: self.owner,
            master: self.master,
            code: initOf GameTokenWallet(self.owner, self.master).code,
        };
    }
}

contract GameToken with Deployable, OwnableTransferable {
    totalSupply: Int as coins;
    owner: Address;
    mintable: Bool;
    content: Cell;

    init(owner: Address, content: Cell) {
        self.totalSupply = 0;
        self.owner = owner;
        self.mintable = true;
        self.content = content;
    }

    receive(msg: RequestTokenWalletBinding) {
        require(sender() == msg.owner, "binding requester must be wallet owner");
        let initState = initOf GameTokenWallet(msg.owner, myAddress());
        send(SendParameters {
            to: msg.owner,
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: ConfirmTokenWalletBinding {
                wallet: contractAddress(initState),
            }.toCell(),
        });
    }

    receive(msg: MintGenesis) {
        self.requireOwner();
        require(self.mintable && self.totalSupply == 0, "genesis supply already issued");
        self.totalSupply = MAX_SUPPLY;
        self.mintable = false;

        let initState = initOf GameTokenWallet(msg.receiver, myAddress());
        send(SendParameters {
            to: contractAddress(initState),
            value: 0,
            mode: SendRemainingValue,
            bounce: true,
            body: JettonTransferInternal {
                queryId: msg.queryId,
                amount: MAX_SUPPLY,
                from: myAddress(),
                responseDestination: self.owner,
                forwardTonAmount: ton("0.05"),
                forwardPayload: beginCell().storeUint(GENESIS_MINT_TAG, 32).endCell().asSlice(),
            }.toCell(),
            code: initState.code,
            data: initState.data,
        });
    }

    receive(msg: JettonBurnNotification) {
        let expected = contractAddress(initOf GameTokenWallet(msg.sender, myAddress()));
        require(sender() == expected, "not a valid wallet");
        require(self.totalSupply >= msg.amount, "burn exceeds supply");
        self.totalSupply -= msg.amount;
    }

    bounced(src: Slice) {
        let op = src.loadUint(32);
        if (op == 0x178d4519) {
            src.loadUint(64);
            self.totalSupply -= src.loadCoins();
            if (self.totalSupply < MAX_SUPPLY) {
                self.mintable = true;
            }
        }
    }

    receive(msg: UpdateContent) {
        self.requireOwner();
        require(self.totalSupply == 0 && self.mintable, "metadata is immutable after genesis");
        self.content = msg.content;
    }

    get fun get_wallet_address(owner: Address): Address {
        return contractAddress(initOf GameTokenWallet(owner, myAddress()));
    }

    get fun get_jetton_data(): JettonData {
        return JettonData {
            totalSupply: self.totalSupply,
            mintable: self.mintable,
            owner: self.owner,
            content: self.content,
            walletCode: initOf GameTokenWallet(myAddress(), myAddress()).code,
        };
    }

    get fun max_supply(): Int {
        return MAX_SUPPLY;
    }
}

message UpdateContent {
    content: Cell;
}
