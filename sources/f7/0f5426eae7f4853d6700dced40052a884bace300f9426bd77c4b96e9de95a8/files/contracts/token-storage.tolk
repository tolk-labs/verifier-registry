import "creation"
import "storage"

const TOKEN_KIND_FIXED_FREE = 10
const TOKEN_KIND_CAPPED = 14

struct TokenParams {
    supply: coins
    maxSupply: coins
    metadata: cell
}

struct TokenRoles {
    creator: address
    adminAddress: address?
    nextAdminAddress: address?
}

struct TokenStorage {
    factory: address
    kind: uint16
    index: uint64
    queryId: uint64
    totalSupply: coins
    maxSupply: coins
    mintingLockedUntil: uint32
    metadataBits: uint32
    metadataCells: uint16
    roles: Cell<TokenRoles>
    metadata: cell
}

fun ContractLoader.endToken(mutate self): TokenStorage {
    return {
        factory: self.factory,
        kind: self.kind,
        index: self.index,
        queryId: self.rest.loadAny(),
        totalSupply: self.rest.loadAny(),
        maxSupply: self.rest.loadAny(),
        mintingLockedUntil: self.rest.loadAny(),
        metadataBits: self.rest.loadAny(),
        metadataCells: self.rest.loadAny(),
        roles: self.rest.loadAny(),
        metadata: self.rest.loadAny(),
    };
}

fun TokenStorage.save(self) {
    contract.setData(self.toCell());
}

fun loadStartedToken(): TokenStorage {
    var loading = ContractLoader.start();
    return loading.endToken();
}

fun loadTokenIfStarted(): TokenStorage? {
    var loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        return null;
    }
    return loading.endToken();
}

struct TokenDataReply {
    totalSupply: int
    mintable: bool
    adminAddress: any_address
    jettonContent: Cell<OnchainMetadataReply>
    jettonWalletCode: cell
}
