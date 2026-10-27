// Отдельный nominal type: compute gas нельзя случайно заменить суммой nanoTON.
// Один int на TVM stack; тип не входит в storage или message schemas.
struct GasUnits {
    value: int
}

fun GasUnits.add(self, other: GasUnits): GasUnits {
    return { value: self.value + other.value };
}

fun GasUnits.multiplyBy(self, count: int): GasUnits {
    return { value: self.value * count };
}
