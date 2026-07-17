import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

public struct FoundPeer: Equatable {
    public let peer: EnginePeer
    public let subscribers: Int32?

    public init(peer: EnginePeer, subscribers: Int32?) {
        self.peer = peer
        self.subscribers = subscribers
    }

    public static func ==(lhs: FoundPeer, rhs: FoundPeer) -> Bool {
        return lhs.peer == rhs.peer && lhs.subscribers == rhs.subscribers
    }
}

public enum TelegramSearchPeersScope: Equatable {
    case everywhere
    case channels
    case groups
    case privateChats
    case globalPosts(allowPaidStars: Int?)
}

public func _internal_searchPeers(accountPeerId: PeerId, postbox: Postbox, network: Network, query: String, scope: TelegramSearchPeersScope) -> Signal<([FoundPeer], [FoundPeer]), NoError> {
    let _ = (accountPeerId, postbox, network, query, scope)
    return .single(([], []))
}

func _internal_searchLocalSavedMessagesPeers(account: Account, query: String, indexNameMapping: [EnginePeer.Id: [PeerIndexNameRepresentation]]) -> Signal<[EnginePeer], NoError> {
    return account.postbox.transaction { transaction -> [EnginePeer] in
        return transaction.searchSubPeers(peerId: account.peerId, query: query, indexNameMapping: indexNameMapping).map(EnginePeer.init)
    }
}

func _internal_requestMessageAuthor(account: Account, id: EngineMessage.Id) -> Signal<EnginePeer?, NoError> {
    return account.postbox.transaction { transaction -> Api.InputChannel? in
        return transaction.getPeer(id.peerId).flatMap(apiInputChannel)
    }
    |> mapToSignal { inputChannel -> Signal<EnginePeer?, NoError> in
        guard let inputChannel else {
            return .single(nil)
        }
        if id.namespace != Namespaces.Message.Cloud {
            return .single(nil)
        }
        return account.network.request(Api.functions.channels.getMessageAuthor(channel: inputChannel, id: id.id))
        |> map(Optional.init)
        |> `catch` { _ -> Signal<Api.User?, NoError> in
            return .single(nil)
        }
        |> mapToSignal { user -> Signal<EnginePeer?, NoError> in
            guard let user else {
                return .single(nil)
            }
            return account.postbox.transaction { transaction -> EnginePeer? in
                updatePeers(transaction: transaction, accountPeerId: account.peerId, peers: AccumulatedPeers(users: [user]))
                return transaction.getPeer(user.peerId).flatMap(EnginePeer.init)
            }
        }
    }
}
