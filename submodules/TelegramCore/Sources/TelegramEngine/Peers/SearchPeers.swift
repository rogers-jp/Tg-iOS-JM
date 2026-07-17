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
    switch scope {
    case .channels, .groups, .globalPosts:
        return .single(([], []))
    case .everywhere, .privateChats:
        break
    }

    let searchResult = network.request(Api.functions.contacts.search(flags: 0, q: query, limit: 20), automaticFloodWait: false)
    |> map(Optional.init)
    |> `catch` { _ in
        return Signal<Api.contacts.Found?, NoError>.single(nil)
    }

    return searchResult
    |> mapToSignal { result -> Signal<([FoundPeer], [FoundPeer]), NoError> in
        guard let result else {
            return .single(([], []))
        }

        switch result {
        case let .found(foundData):
            let (myResults, results, _, users) = (foundData.myResults, foundData.results, foundData.chats, foundData.users)
            return postbox.transaction { transaction -> ([FoundPeer], [FoundPeer]) in
                let parsedPeers = AccumulatedPeers(transaction: transaction, users: users)
                updatePeers(transaction: transaction, accountPeerId: accountPeerId, peers: parsedPeers)

                func mapUsers(_ source: [Api.Peer]) -> [FoundPeer] {
                    var mapped: [FoundPeer] = []
                    for result in source {
                        let peerId: PeerId = result.peerId
                        guard let peer = parsedPeers.get(peerId), let user = peer as? TelegramUser, user.botInfo == nil else {
                            continue
                        }
                        mapped.append(FoundPeer(peer: EnginePeer(user), subscribers: user.subscriberCount))
                    }
                    return mapped
                }

                return (mapUsers(myResults), mapUsers(results))
            }
        }
    }
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
