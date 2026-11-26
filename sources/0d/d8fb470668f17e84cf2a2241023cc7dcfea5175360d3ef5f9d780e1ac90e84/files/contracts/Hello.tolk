struct Storage {
    greeting: string
}

contract Hello {
    author: "hello"
    version: "0.1.0"
    description: "Hello-world contract"
    storage: Storage
}

fun onInternalMessage(_in: InMessage) {}

get fun greeting(): string {
    return Storage.fromCell(contract.getData()).greeting;
}
