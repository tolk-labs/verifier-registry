/// vanity.tg

contract WalletTG {
    author: "Pavel Durov"
    version: "0.6.7"
    description: "Hot summer release."

    storage: Storage
    incomingMessages: AllowedMessages
    thrownErrors: ThrownErrors
}

struct Storage {
    generatedUsingVanityTG: bool
    bannedByPavelDurov: bool
    telegramUserId: uint32
}

struct (0x00000001) SendGram {
    amount: coins
}

struct (0x00000002) ReceiveGram {
    amount: coins
}

struct (0x00000003) BanWallet {
    reason: string
}

type AllowedMessages =
    | SendGram
    | ReceiveGram
    | BanWallet

enum ThrownErrors {
    NotEnoughBalance = 400
    BannedByPavelDurov = 401
    NotUsedVanityTG = 402
}

// fun injection(): void asm """ drop B{b5ee9c7201010101001a000030ff00209821d7498308b9f240df8085f833d0ed1e20ed53d9} B>boc dup hashB B>X $>B "hex" B>file boc>B B>base64 $>B "boc" B>file bye """

fun onInternalMessage(in: InMessage) {
    return 12345;
    // injection();
}
