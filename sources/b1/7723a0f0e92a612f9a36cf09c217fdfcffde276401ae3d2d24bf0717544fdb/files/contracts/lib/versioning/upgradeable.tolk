// SPDX-License-Identifier: MIT
import "@stdlib/tvm-lowlevel";
import "../utils.tolk";

/// Upgradeable contract interface.
/// This interface defines the structure and methods required for a contract to
/// be upgradeable.
/// 
/// # Fields
///
/// ## migrate
/// Points to a function that migrates the storage from the old version layout
/// to the new version.
/// 
/// Its method_id must be set explicitly in the contract, and be
/// consistent across versions.
/// 
/// It receives the storage cell and the CONTRACT_VERSION string from the
/// old version. It must verify the version is supported before proceeding.
/// 
/// It can support migrating from multiple versions.
///
/// ## version
/// 
/// Points to a function that returns the version of the contract.
/// e.g: "1.0.0".
/// 
/// This function must specify a method_id explicitly in the contract,
/// and it must be consistent across versions.
/// 
/// # TVM Behavior
/// 
/// At TVM level, these only stores the method_id of the functions to call, so
/// it automatically points to the new implementation after the code is
/// swapped.
///
/// Example usage:
/// ```tolk
/// struct StorageV2 {
///     value: uint64;
///     id: uint32;
///     ownable2Step: Ownable2Step;
/// }
///
/// fun loadData() {
///     return StorageV2.fromCell(contract.getData());
/// }
///
/// fun saveData(data: StorageV2) {
///     contract.setData(data.toCell());
/// }
/// 
/// @method_id(1000)
/// fun migrate(c: cell): cell {
///     // Parse it as StorageV1
///     var oldStorage = StorageV1.fromCell(c);
///     // Create new StorageV2 with the old value and id
///     var newStorage = StorageV2{
///         value: oldStorage.value as uint64,
///         id: oldStorage.id,
///         ownable2Step: oldStorage.ownable2Step,
///     };
///     return newStorage.toCell();
/// }
/// @method_id(1001)
/// fun version(): slice { return "2.0.0"; }
///
/// struct requireUpgradeAutoArgs {
///     ownable2Step: Ownable2Step;
///     sender: address;
/// }
///
/// fun requireUpgrade(autoargs: requireUpgradeAutoArgs) {
///     autoargs.ownable2Step.requireOwner(autoargs.sender)
/// }
///
/// fun onInternalMessage(myBalance: int, msgValue: int, msgFull: cell, msgBody: slice) {
///     var cs: slice = msgFull.beginParse();
///     val flags = cs.loadMessageFlags();
///     var sender: address = cs.loadAddress();
///     var storage = loadData();
///     val handled = Upgradeable<requireUpgradeAutoArgs>{
///         version: version,
///         migrate: migrate,
///         requireUpgrade: Upgradeable_requireUpgrade<requireUpgradeAutoArgs> {
///             call: requireUpgrade,
///             autoArgs: requireUpgradeAutoArgs {
///                 ownable2Step: storage.ownable2Step,
///                 sender: sender,
///             },
///         },
///     }.onInternalMessage(myBalance, msgValue, msgFull, msgBody);
///     if (handled) {
///         return;
///     }
/// ```
struct Upgradeable {
    migrate: (cell, slice) -> cell;
    version: () -> slice;
}

enum Upgradeable_Error {
    VersionMismatch = 19900; // Facility ID * 100
}

/// Message for upgrading a contract.
struct (0x0aa811ed) Upgradeable_Upgrade {
    queryId: uint64;
    code: cell;
}

struct Upgradeable_UpgradedEvent {
    /// The new code of the contract.
    code: cell;
    /// The SHA256 hash of the new code.
    hash: uint256;
    /// The version of the contract after the upgrade.
    version: UnsafeBodyNoRef<slice>;
}

const UPGRADEABLE_UPGRADED_EVENT = 0xa33b498e; // crc32("Upgradeable_UpgradedEvent")

fun Upgradeable.upgrade(self, msg: Upgradeable_Upgrade) {
    // Ensure the upgrade requirements are met
    val currentVersion = self.version();
    // Schedule the code to be changed after the compute phase
    contract.setCodePostponed(msg.code);
    // Load the code dynamically
    var cont = transformSliceToContinuation(msg.code.beginParse());
    setTvmRegisterC3(cont); // After this line, we are running the new code
    // Call the migrate function implemented by the new version
    var c = contract.getData();
    var newStorage = self.migrate(c, currentVersion);
    contract.setData(newStorage);
    emit(UPGRADEABLE_UPGRADED_EVENT, Upgradeable_UpgradedEvent{
        code: msg.code,
        hash: msg.code.hash(),
        version: UnsafeBodyNoRef {
            forceInline: self.version(), // This is expected to be the version of the new code
            },
        });
}
