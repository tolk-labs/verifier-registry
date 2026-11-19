import "creation"
import "fee-rules"
import "token-storage"

const TOKEN_KIND_TAXABLE = 16

struct NamedAddresses {
    first: address?
    second: address?
}

struct FeeTokenParams {
    supply: coins
    metadata: cell
    burnPermille: uint16
    tax1: TaxRule?
    tax2: TaxRule?
    tax3: TaxRule?
    named: Cell<NamedAddresses>?
}

struct FeeTokenStorage {
    factory: address
    kind: uint16
    index: uint64
    queryId: uint64
    totalSupply: coins
    firstSupply: coins
    exclusionsLockedUntil: uint32
    metadataBits: uint32
    metadataCells: uint16
    roles: Cell<TokenRoles>
    rules: Cell<FeeRules>
    metadata: cell
}

fun ContractLoader.endFeeToken(mutate self): FeeTokenStorage {
    return {
        factory: self.factory,
        kind: self.kind,
        index: self.index,
        queryId: self.rest.loadAny(),
        totalSupply: self.rest.loadAny(),
        firstSupply: self.rest.loadAny(),
        exclusionsLockedUntil: self.rest.loadAny(),
        metadataBits: self.rest.loadAny(),
        metadataCells: self.rest.loadAny(),
        roles: self.rest.loadAny(),
        rules: self.rest.loadAny(),
        metadata: self.rest.loadAny(),
    };
}

fun FeeTokenStorage.save(self) {
    contract.setData(self.toCell());
}

fun loadStartedFeeToken(): FeeTokenStorage {
    var loading = ContractLoader.start();
    return loading.endFeeToken();
}

fun loadFeeTokenIfStarted(): FeeTokenStorage? {
    var loading = ContractLoader.start();
    if (loading.isUnstarted()) {
        return null;
    }
    return loading.endFeeToken();
}

struct FeeRulesReply {
    burnPermille: int
    tax1Permille: int
    tax1Address: any_address
    tax2Permille: int
    tax2Address: any_address
    tax3Permille: int
    tax3Address: any_address
    creator: any_address
    named1: any_address
    named2: any_address
}
