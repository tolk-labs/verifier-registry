// SPDX-License-Identifier: MIT
import "types"

const DeployableNamespace_CCIPSendExecutor: Namespace = 0;
const DeployableNamespace_ReceiveExecutor: Namespace = 1;
const DeployableNamespace_MerkleRoot: Namespace = 2;

struct Namespaced<T> {
    namespace: Namespace;
    id: T;
}

type Namespace = uint32;

struct NamespacedDeployableDataProps<T> {
    namespace: Namespace;
    owner: address;
    id: T;
}

fun NamespacedDeployableData<T>(props: NamespacedDeployableDataProps<T>): cell {
    return Deployable<Namespaced<T>> {
        owner: props.owner,
        id: Namespaced<T> {
            namespace: props.namespace,
            id: props.id,
        },
    }.toCell();
}
