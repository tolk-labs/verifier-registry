tolk 1.2

// CyberJoule (CKJ) jetton minter (TEP-74). A player mints with an authorization that the game server
// signs, and burning through a jetton wallet is how tokens go back into the game. The admin can also
// mint, set the fee and the treasury, and replace this contract's code and data (UpgradeCode).

const ERROR_UNAUTHORIZED: int = 73;
const ERROR_INVALID_WALLET: int = 74;
const ERROR_EXPIRED: int = 75;
const ERROR_INVALID_SIGNATURE: int = 76;
const ERROR_INSUFFICIENT_TON: int = 77;
const ERROR_INVALID_SEQNO: int = 78;
const ERROR_ZERO_AMOUNT: int = 79;
const ERROR_INVALID_GENERATION: int = 80;
const ERROR_NO_PENDING_ADMIN: int = 81;
const ERROR_UNKNOWN_OP: int = 0xFFFF;

const CONTRACT_VERSION: int = 1;

const MIN_FORWARD_TON: int = ton("0.03");  // the least a mint forwards to the jetton wallet: its storage and gas

// Three addresses, two amounts and a key can exceed the 1023 bits of one cell on paper; with real
// amounts they do not, so the compiler's size check is silenced. The pending admin is kept in a ref.
@overflow1023_policy("suppress")
struct Storage {
    totalSupply: coins                // tokens in circulation
    adminAddress: address             // the admin wallet
    content: cell                     // metadata (TEP-64)
    walletCode: cell                  // code of the jetton wallets
    adminPublicKey: uint256           // the Ed25519 key mint authorizations are signed with
    userSeqnos: map<address, uint32>  // each wallet's next authorization number (none is used twice)
    treasuryAddress: address          // receives the mint and burn fees
    fee: coins                        // the fee of a mint or a burn
    generation: uint32                // raised by ResetSeqnos: voids every authorization signed before
    pendingAdmin: cell                // ^(the address offered the admin role, or addr_none)
}

fun Storage.load(): Storage {
    return Storage.fromCell(contract.getData());
}

fun Storage.save(self) {
    contract.setData(self.toCell());
}

// ============== Messages ==============

// The admin mints to an address
struct (0x642b7d07) MintMessage {
    queryId: uint64
    toAddress: address          // who receives the tokens
    tonAmount: coins            // GRAM sent on to the jetton wallet
    masterMsg: cell             // begins with the amount to mint
}

// A jetton wallet reports a burn (TEP-74)
struct (0x7bdd97de) BurnNotification {
    queryId: uint64
    amount: coins
    senderAddress: address       // the wallet's owner
    responseDestination: address  // where the change goes
    customPayload: cell?         // optional data for the game (the player's id)
}

// The admin offers the role to another address (first step)
struct (0x00000003) ChangeAdmin {
    queryId: uint64
    newAdmin: address
}

// The address it was offered to takes the role (second step)
struct (0x0000000a) ClaimAdmin {
    queryId: uint64
}

// The admin replaces the metadata
struct (0x00000004) ChangeContent {
    queryId: uint64
    newContent: cell
}

// TEP-89: anyone asks for an owner's jetton wallet address
struct (0x2c76b973) ProvideWalletAddress {
    queryId: uint64
    ownerAddress: address
    includeAddress: bool        // whether the answer repeats the owner's address
}

// A mint sent by the wallet that receives the tokens, carrying the server's authorization
struct (0x7b5c1d8e) UserMintMessage {
    queryId: uint64
    amount: coins               // in the token's smallest unit
    seqno: uint32               // the wallet's authorization number
    generation: uint32          // the minter's generation when it was signed
    expiry: uint32              // unix time after which it is void
    forwardTonAmount: coins     // GRAM sent on to the jetton wallet (MIN_FORWARD_TON at least)
    signatureCell: cell         // the Ed25519 signature, in a cell of its own
}

// The admin sets the key that signs mint authorizations
struct (0x00000005) SetAdminPublicKey {
    queryId: uint64
    publicKey: uint256
}

// The admin changes the treasury
struct (0x00000006) ChangeTreasury {
    queryId: uint64
    newTreasury: address
}

// The admin sets the fee
struct (0x00000007) SetFee {
    queryId: uint64
    newFee: coins
}

// The admin sends GRAM held above the reserve to the treasury (amount 0: all of it)
struct (0x00000008) WithdrawTon {
    queryId: uint64
    amount: coins
}

// The admin voids every authorization signed so far and empties the sequence numbers (a new
// generation): also the way to shrink the storage when it has grown large
struct (0x00000009) ResetSeqnos {
    queryId: uint64
}

// The admin replaces the contract's code and data
struct (0x2508d66a) UpgradeCode {
    queryId: uint64
    newData: cell
    newCode: cell
}

// Emitted when the code is replaced
struct (0x2508d66b) UpgradeEvent {
    queryId: uint64
    oldVersion: uint32
    newVersion: uint32
}

// ============== Events ==============
// External messages that record the admin's operations

// The admin role changed hands
struct (0x2508d66c) AdminChangedEvent {
    queryId: uint64
    oldAdmin: address
    newAdmin: address
}

// The treasury changed
struct (0x2508d66d) TreasuryChangedEvent {
    queryId: uint64
    oldTreasury: address
    newTreasury: address
}

// The fee changed
struct (0x2508d66e) FeeChangedEvent {
    queryId: uint64
    oldFee: coins
    newFee: coins
}

// The signing key changed
struct (0x2508d66f) AdminPublicKeyChangedEvent {
    queryId: uint64
    newPublicKey: uint256
}

// The sequence numbers were reset
struct (0x2508d670) SeqnosResetEvent {
    queryId: uint64
    newGeneration: uint32
}

// TEP-89: the answer to ProvideWalletAddress
struct (0xd1735400) TakeWalletAddress {
    queryId: uint64
    walletAddress: address
    ownerAddress: address?
}

// TEP-74 excesses: change returned
struct (0xd53276db) Excesses {
    queryId: uint64
}

// TEP-74 internal_transfer, minter to wallet: the mint itself
struct (0x178d4519) InternalTransfer {
    queryId: uint64
    amount: coins
    fromAddress: address
    responseAddress: address
    forwardTonAmount: coins
    forwardPayload: cell?
}

// Every message the minter accepts
type MinterMessage = MintMessage | BurnNotification | ChangeAdmin | ClaimAdmin | ChangeContent | ProvideWalletAddress | UserMintMessage | SetAdminPublicKey | ChangeTreasury | SetFee | WithdrawTon | ResetSeqnos | UpgradeCode;

// ============== Helpers ==============

// The data a jetton wallet is deployed with
fun createWalletData(
    ownerAddress: address,
    minterAddress: address,
    walletCode: cell
): cell {
    return beginCell()
        .storeCoins(0)  // a wallet starts empty: its address is that of its initial data
        .storeAddress(ownerAddress)
        .storeAddress(minterAddress)
        .storeRef(walletCode)
        .endCell();
}

fun getWalletDeployAddress(
    ownerAddress: address,
    minterAddress: address,
    walletCode: cell
): AutoDeployAddress {
    val walletData = createWalletData(ownerAddress, minterAddress, walletCode);
    return {
        stateInit: {
            code: walletCode,
            data: walletData
        }
    };
}

fun calculateWalletAddress(
    ownerAddress: address,
    minterAddress: address,
    walletCode: cell
): address {
    val deployAddr = getWalletDeployAddress(ownerAddress, minterAddress, walletCode);
    return deployAddr.calculateAddress();
}

// ============== Entry point ==============

fun onInternalMessage(in: InMessage) {
    // a plain transfer is accepted
    if (in.body.isEmpty()) {
        return;
    }

    val msg = lazy MinterMessage.fromSlice(in.body);
    var storage = lazy Storage.load();

    match (msg) {
        MintMessage => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            // the amount is the first field of the master message
            var masterSlice = msg.masterMsg.beginParse();
            val mintAmount = masterSlice.loadCoins();

            assert(mintAmount > 0) throw ERROR_ZERO_AMOUNT;

            val walletDeploy = getWalletDeployAddress(
                msg.toAddress,
                contract.getAddress(),
                storage.walletCode
            );

            storage.totalSupply += mintAmount;
            storage.save();

            val internalTransferMsg = InternalTransfer {
                queryId: msg.queryId,
                amount: mintAmount,
                fromAddress: contract.getAddress(),
                responseAddress: storage.adminAddress,
                forwardTonAmount: 0,
                forwardPayload: null
            };

            // Deploys the wallet if it does not exist yet. Should the wallet refuse, the bounce takes the amount
            // off the supply again (onBouncedMessage).
            createMessage({
                bounce: true,
                dest: walletDeploy,
                value: msg.tonAmount,
                body: internalTransferMsg
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        BurnNotification => {
            // only the jetton wallet of the owner it names can report a burn
            val expectedWallet = calculateWalletAddress(
                msg.senderAddress,
                contract.getAddress(),
                storage.walletCode
            );
            assert(in.senderAddress == expectedWallet) throw ERROR_INVALID_WALLET;

            // the burn pays the fee and its own gas
            assert(in.valueCoins >= storage.fee + ton("0.02")) throw ERROR_INSUFFICIENT_TON;

            storage.totalSupply -= msg.amount;
            storage.save();

            // what is left after the fee and the gas goes back to the owner
            val gasReserve = ton("0.01");
            val excessAmount = in.valueCoins - storage.fee - gasReserve;

            createMessage({
                bounce: false,
                dest: storage.treasuryAddress,
                value: storage.fee,
                body: beginCell().endCell()
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);

            if (msg.responseDestination != createAddressNone() && excessAmount > 0) {
                val excessMsg = Excesses {
                    queryId: msg.queryId
                };

                createMessage({
                    bounce: false,
                    dest: msg.responseDestination,
                    value: excessAmount,
                    body: excessMsg
                }).send(SEND_MODE_PAY_FEES_SEPARATELY + SEND_MODE_IGNORE_ERRORS);
            }
        }

        ChangeAdmin => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            storage.pendingAdmin = beginCell().storeAddress(msg.newAdmin).endCell();
            storage.save();
        }

        ClaimAdmin => {
            var pendingAdminSlice = storage.pendingAdmin.beginParse();
            val addrType = pendingAdminSlice.preloadUint(2);

            assert(addrType != 0) throw ERROR_NO_PENDING_ADMIN;

            val pendingAdminAddr = pendingAdminSlice.loadAddress();

            assert(in.senderAddress == pendingAdminAddr) throw ERROR_UNAUTHORIZED;

            val oldAdmin = storage.adminAddress;

            storage.adminAddress = pendingAdminAddr;
            storage.pendingAdmin = beginCell().storeUint(0, 2).endCell();  // addr_none
            storage.save();

            val adminChangedEvent = AdminChangedEvent {
                queryId: msg.queryId,
                oldAdmin: oldAdmin,
                newAdmin: pendingAdminAddr
            };
            createExternalLogMessage({
                dest: createAddressNone(),
                body: adminChangedEvent
            }).send(SEND_MODE_REGULAR);
        }

        ChangeContent => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            storage.content = msg.newContent;
            storage.save();
        }

        ProvideWalletAddress => {
            val walletAddress = calculateWalletAddress(
                msg.ownerAddress,
                contract.getAddress(),
                storage.walletCode
            );

            val responseMsg = TakeWalletAddress {
                queryId: msg.queryId,
                walletAddress: walletAddress,
                ownerAddress: msg.includeAddress ? msg.ownerAddress : null
            };

            createMessage({
                bounce: false,
                dest: in.senderAddress,
                value: 0,
                body: responseMsg
            }).send(SEND_MODE_CARRY_ALL_REMAINING_MESSAGE_VALUE);
        }

        UserMintMessage => {
            // the sender is the one who receives the tokens
            val toAddress = in.senderAddress;

            assert(msg.amount > 0) throw ERROR_ZERO_AMOUNT;

            // signed for this generation, and used once: it names the wallet's next number
            assert(msg.generation == storage.generation) throw ERROR_INVALID_GENERATION;

            val seqnoResult = storage.userSeqnos.get(toAddress);
            val storedSeqno: uint32 = seqnoResult.isFound ? seqnoResult.loadValue() : 0;
            assert(msg.seqno == storedSeqno) throw ERROR_INVALID_SEQNO;

            assert(blockchain.now() <= msg.expiry) throw ERROR_EXPIRED;

            assert(msg.forwardTonAmount >= MIN_FORWARD_TON) throw ERROR_INSUFFICIENT_TON;

            // enough for the gas, the wallet's deployment, the fee and the forward amount
            assert(in.valueCoins >= msg.forwardTonAmount + storage.fee + ton("0.02")) throw ERROR_INSUFFICIENT_TON;

            // What the server signed: this minter, the receiver, the amount and the replay fields
            val authData = beginCell()
                .storeAddress(contract.getAddress())
                .storeAddress(toAddress)
                .storeCoins(msg.amount)
                .storeUint(msg.seqno, 32)
                .storeUint(msg.generation, 32)
                .storeUint(msg.expiry, 32)
                .endCell();

            val authDataHash = authData.hash();

            val isValid = isSignatureValid(
                authDataHash,
                msg.signatureCell.beginParse(),
                storage.adminPublicKey
            );
            assert(isValid) throw ERROR_INVALID_SIGNATURE;

            val walletDeploy = getWalletDeployAddress(
                toAddress,
                contract.getAddress(),
                storage.walletCode
            );

            storage.userSeqnos.set(toAddress, storedSeqno + 1);
            storage.totalSupply += msg.amount;
            storage.save();

            createMessage({
                bounce: false,
                dest: storage.treasuryAddress,
                value: storage.fee,
                body: beginCell().endCell()
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);

            val internalTransferMsg = InternalTransfer {
                queryId: msg.queryId,
                amount: msg.amount,
                fromAddress: contract.getAddress(),
                responseAddress: toAddress,
                forwardTonAmount: 0,
                forwardPayload: null
            };

            // deploys the wallet if it does not exist yet; a bounce takes the amount off the supply again
            createMessage({
                bounce: true,
                dest: walletDeploy,
                value: msg.forwardTonAmount,
                body: internalTransferMsg
            }).send(SEND_MODE_PAY_FEES_SEPARATELY);
        }

        SetAdminPublicKey => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            storage.adminPublicKey = msg.publicKey;
            storage.save();

            val publicKeyChangedEvent = AdminPublicKeyChangedEvent {
                queryId: msg.queryId,
                newPublicKey: msg.publicKey
            };
            createExternalLogMessage({
                dest: createAddressNone(),
                body: publicKeyChangedEvent
            }).send(SEND_MODE_REGULAR);
        }

        ChangeTreasury => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            val oldTreasury = storage.treasuryAddress;

            storage.treasuryAddress = msg.newTreasury;
            storage.save();

            val treasuryChangedEvent = TreasuryChangedEvent {
                queryId: msg.queryId,
                oldTreasury: oldTreasury,
                newTreasury: msg.newTreasury
            };
            createExternalLogMessage({
                dest: createAddressNone(),
                body: treasuryChangedEvent
            }).send(SEND_MODE_REGULAR);
        }

        SetFee => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            val oldFee = storage.fee;

            storage.fee = msg.newFee;
            storage.save();

            val feeChangedEvent = FeeChangedEvent {
                queryId: msg.queryId,
                oldFee: oldFee,
                newFee: msg.newFee
            };
            createExternalLogMessage({
                dest: createAddressNone(),
                body: feeChangedEvent
            }).send(SEND_MODE_REGULAR);
        }

        WithdrawTon => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            // the reserve stays, for the minter's rent
            val reserve = ton("0.05");
            val balance = contract.getOriginalBalance();
            val available: coins = balance > reserve ? balance - reserve : 0;

            val withdrawAmount: coins = msg.amount == 0 ? available : min(msg.amount, available);

            if (withdrawAmount > 0) {
                createMessage({
                    bounce: false,
                    dest: storage.treasuryAddress,
                    value: withdrawAmount,
                    body: beginCell().endCell()
                }).send(SEND_MODE_PAY_FEES_SEPARATELY);
            }
        }

        ResetSeqnos => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            storage.userSeqnos = createEmptyMap();

            storage.generation += 1;

            storage.save();

            val seqnosResetEvent = SeqnosResetEvent {
                queryId: msg.queryId,
                newGeneration: storage.generation
            };
            createExternalLogMessage({
                dest: createAddressNone(),
                body: seqnosResetEvent
            }).send(SEND_MODE_REGULAR);
        }

        UpgradeCode => {
            assert(in.senderAddress == storage.adminAddress) throw ERROR_UNAUTHORIZED;

            val upgradeEvent = UpgradeEvent {
                queryId: msg.queryId,
                oldVersion: CONTRACT_VERSION,
                newVersion: 0
            };
            createExternalLogMessage({
                dest: createAddressNone(),
                body: upgradeEvent
            }).send(SEND_MODE_REGULAR);

            contract.setData(msg.newData);

            // the new code takes effect after this transaction
            contract.setCodePostponed(msg.newCode);
        }

        else => {
            throw ERROR_UNKNOWN_OP;
        }
    }
}

// A jetton wallet refused a mint: the amount comes off the supply again
fun onBouncedMessage(in: InMessageBounced) {
    var body = in.bouncedBody;

    // the 0xFFFFFFFF prefix of a bounced body
    body.skipBits(32);

    val op = body.loadUint(32);

    // internal_transfer
    if (op == 0x178d4519) {
        body.loadUint(64);  // queryId
        val amount = body.loadCoins();

        var storage = lazy Storage.load();
        storage.totalSupply -= amount;
        storage.save();
    }
}

// ============== Get methods ==============

// TEP-74: (total_supply, mintable, admin_address, content, wallet_code)
get fun get_jetton_data(): (coins, int, address, cell, cell) {
    val storage = lazy Storage.load();
    return (
        storage.totalSupply,
        -1,  // mintable
        storage.adminAddress,
        storage.content,
        storage.walletCode
    );
}

// TEP-74: an owner's jetton wallet address
get fun get_wallet_address(ownerAddress: slice): address {
    val storage = lazy Storage.load();
    val owner = ownerAddress.loadAddress();
    return calculateWalletAddress(
        owner,
        contract.getAddress(),
        storage.walletCode
    );
}

// The key mint authorizations are signed with
get fun get_admin_public_key(): int {
    val storage = lazy Storage.load();
    return storage.adminPublicKey;
}

// The address the admin role is offered to, or null
get fun get_pending_admin(): address? {
    val storage = lazy Storage.load();
    var pendingSlice = storage.pendingAdmin.beginParse();
    // addr_none begins with 00
    val addrType = pendingSlice.preloadUint(2);
    if (addrType == 0) {
        return null;
    }
    return pendingSlice.loadAddress();
}

// A wallet's next authorization number
get fun get_user_seqno(userAddress: slice): uint32 {
    val storage = lazy Storage.load();
    val addr = userAddress.loadAddress();
    val result = storage.userSeqnos.get(addr);
    return result.isFound ? result.loadValue() : 0;
}

get fun get_treasury_address(): address {
    val storage = lazy Storage.load();
    return storage.treasuryAddress;
}

get fun get_fee(): coins {
    val storage = lazy Storage.load();
    return storage.fee;
}

get fun get_generation(): uint32 {
    val storage = lazy Storage.load();
    return storage.generation;
}

get fun get_version(): int {
    return CONTRACT_VERSION;
}
