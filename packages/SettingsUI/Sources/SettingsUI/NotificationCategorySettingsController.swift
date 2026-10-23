import Cocoa
import TGUIKit
import SwiftSignalKit
import Postbox
import TelegramCore
import InAppSettings
import InputDataUI
import GeneralRows
import Localization
import TelegramContext
import TelegramTheme
import ColorPalette
import TelegramUtils
import TelegramIconsTheme
import LocalAnimations
import TelegramMediaUtils
import ShortPeerRow
import SelectPeersUI
import AlertsUI

private let privateChatsIcon = generateSettingsIcon(TelegramThemeHooks.shared.image(.iconSettingsNotifyPrivateChats).precomposed(flipVertical: true))
private let groupChatsIcon = generateSettingsIcon(TelegramThemeHooks.shared.image(.iconSettingsNotifyGroupChats).precomposed(flipVertical: true))
private let channelsIcon = generateSettingsIcon(TelegramThemeHooks.shared.image(.iconSettingsNotifyChannels).precomposed(flipVertical: true))
let reactionsNotificationIcon = generateSettingsIcon(TelegramThemeHooks.shared.image(.iconSettingsNotifyReactions).precomposed(flipVertical: true))

public enum NotificationSettingsCategory: Equatable {
    case privateChats
    case groupChats
    case channels

    var title: String {
        switch self {
        case .privateChats:
            return strings().notificationSettingsPrivateChats
        case .groupChats:
            return strings().notificationSettingsGroupChats
        case .channels:
            return strings().notificationSettingsChannels
        }
    }

    var icon: CGImage {
        switch self {
        case .privateChats:
            return privateChatsIcon
        case .groupChats:
            return groupChatsIcon
        case .channels:
            return channelsIcon
        }
    }

    fileprivate var selectSettings: SelectPeerSettings {
        switch self {
        case .privateChats:
            return [.contacts, .remote, .bots]
        case .groupChats:
            return [.groups, .remote]
        case .channels:
            return [.channels, .remote]
        }
    }

    func messageSettings(_ settings: GlobalNotificationSettingsSet) -> MessageNotificationSettings {
        switch self {
        case .privateChats:
            return settings.privateChats
        case .groupChats:
            return settings.groupChats
        case .channels:
            return settings.channels
        }
    }

    func updateMessageSettings(_ settings: inout GlobalNotificationSettingsSet, _ f: (inout MessageNotificationSettings) -> Void) {
        switch self {
        case .privateChats:
            f(&settings.privateChats)
        case .groupChats:
            f(&settings.groupChats)
        case .channels:
            f(&settings.channels)
        }
    }

    func contains(_ peer: EnginePeer) -> Bool {
        switch peer {
        case .user, .secretChat:
            return self == .privateChats
        case .legacyGroup:
            return self == .groupChats
        case let .channel(channel):
            if case .broadcast = channel.info {
                return self == .channels
            } else {
                return self == .groupChats
            }
        case .community:
            return false
        }
    }
}

func effectiveCategorySound(_ sound: PeerMessageSound) -> PeerMessageSound {
    if sound == defaultCloudPeerNotificationSound {
        return .default
    }
    return sound
}

public struct NotificationException: Equatable {
    public let peer: EnginePeer
    public let settings: TelegramPeerNotificationSettings

    public static func ==(lhs: NotificationException, rhs: NotificationException) -> Bool {
        return lhs.peer == rhs.peer && lhs.settings.isEqual(to: rhs.settings)
    }

    func isEffectivelyMuted(now: Int32) -> Bool {
        if case let .muted(until) = settings.muteState, until > now {
            return true
        }
        return false
    }

    func hasCustomSettings(for category: NotificationSettingsCategory) -> Bool {
        guard category.contains(peer) else {
            return false
        }
        if case .default = settings.muteState {
            return settings.messageSound != .default
        }
        return true
    }
}

public final class NotificationExceptionsContext {
    private let context: any AccountContextProtocol
    private let peerIds = ValuePromise<[PeerId]>([], ignoreRepeated: true)
    private let peerIdsValue = Atomic<[PeerId]>(value: [])
    private let serverList = Promise<NotificationExceptionsList?>(nil)
    private let loadedPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let disposable = MetaDisposable()

    public init(context: any AccountContextProtocol) {
        self.context = context
        self.disposable.set((context.engine.peers.notificationExceptionsList() |> deliverOnMainQueue).start(next: { [weak self] list in
            guard let self else {
                return
            }
            let ids = Array(list.settings.keys)
            self.serverList.set(.single(list))
            self.updatePeerIds { current in
                var current = current
                for id in ids where !current.contains(id) {
                    current.append(id)
                }
                return current
            }
            self.loadedPromise.set(true)
        }))
    }

    deinit {
        disposable.dispose()
    }

    private func updatePeerIds(_ f: ([PeerId]) -> [PeerId]) {
        self.peerIds.set(self.peerIdsValue.modify(f))
    }

    func add(_ peerId: PeerId) {
        self.updatePeerIds { current in
            return [peerId] + current.filter { $0 != peerId }
        }
    }

    func remove(_ peerIds: [PeerId]) {
        self.updatePeerIds { current in
            return current.filter { !peerIds.contains($0) }
        }
    }

    func removeAll() {
        self.remove(self.peerIdsValue.with { $0 })
    }

    var loaded: Signal<Bool, NoError> {
        return self.loadedPromise.get()
    }

    var exceptions: Signal<[NotificationException], NoError> {
        let engine = self.context.engine
        let postbox = self.context.account.postbox
        let accountPeerId = self.context.account.peerId
        let serverList = self.serverList.get()
        return self.peerIds.get() |> mapToSignal { peerIds -> Signal<[NotificationException], NoError> in
            if peerIds.isEmpty {
                return .single([])
            }
            let key: PostboxViewKey = .peerNotificationSettings(peerIds: Set(peerIds))
            let settings = postbox.combinedView(keys: [key]) |> map { view -> [PeerId: TelegramPeerNotificationSettings] in
                let values = (view.views[key] as? PeerNotificationSettingsView)?.notificationSettings ?? [:]
                var result: [PeerId: TelegramPeerNotificationSettings] = [:]
                for (peerId, value) in values {
                    if let value = value as? TelegramPeerNotificationSettings {
                        result[peerId] = value
                    }
                }
                return result
            }
            let peers = engine.data.subscribe(EngineDataMap(peerIds.map { TelegramEngine.EngineData.Item.Peer.Peer(id: $0) }))
            return combineLatest(settings, peers, serverList) |> map { settings, peers, serverList in
                var result: [NotificationException] = []
                for peerId in peerIds where peerId != accountPeerId {
                    guard let peer = peers[peerId].flatMap({ $0 }) ?? serverList?.peers[peerId], !peer.isDeleted else {
                        continue
                    }
                    if let value = settings[peerId] ?? serverList?.settings[peerId] {
                        result.append(NotificationException(peer: peer, settings: value))
                    }
                }
                return result
            }
        }
    }

    func exceptions(for category: NotificationSettingsCategory) -> Signal<[NotificationException], NoError> {
        return self.exceptions |> map { exceptions in
            return exceptions.filter { $0.hasCustomSettings(for: category) }.sorted(by: { lhs, rhs in
                return lhs.peer._asPeer().displayTitle.lowercased() < rhs.peer._asPeer().displayTitle.lowercased()
            })
        }
    }
}

private final class Arguments {
    let context: any AccountContextProtocol
    let toggleEnabled:()->Void
    let togglePreviews:()->Void
    let openSound:()->Void
    let addException:()->Void
    let deleteAll:()->Void
    let openPeer:(PeerId)->Void
    let exceptionMenu:(NotificationException)->[ContextMenuItem]
    init(context: any AccountContextProtocol, toggleEnabled:@escaping()->Void, togglePreviews:@escaping()->Void, openSound:@escaping()->Void, addException:@escaping()->Void, deleteAll:@escaping()->Void, openPeer:@escaping(PeerId)->Void, exceptionMenu:@escaping(NotificationException)->[ContextMenuItem]) {
        self.context = context
        self.toggleEnabled = toggleEnabled
        self.togglePreviews = togglePreviews
        self.openSound = openSound
        self.addException = addException
        self.deleteAll = deleteAll
        self.openPeer = openPeer
        self.exceptionMenu = exceptionMenu
    }
}

private struct State : Equatable {
    var settings: GlobalNotificationSettingsSet = .defaultSettings
    var inAppTone: PeerMessageSound = .default
    var soundList: NotificationSoundList?
    var exceptions: [NotificationException] = []
    var loaded: Bool = false
    var settingsLoaded: Bool = false
}

private let _id_enabled = InputDataIdentifier("_id_enabled")
private let _id_previews = InputDataIdentifier("_id_previews")
private let _id_sound = InputDataIdentifier("_id_sound")
private let _id_add_exception = InputDataIdentifier("_id_add_exception")
private let _id_delete_all = InputDataIdentifier("_id_delete_all")
private let _id_loading = InputDataIdentifier("_id_loading")
private func _id_exception(_ peerId: PeerId) -> InputDataIdentifier {
    return InputDataIdentifier("_id_exception_\(peerId.toInt64())")
}

public enum NotificationCategoryEntryTag: ItemListItemTag {
    case show
    case preview
    case sound
    case addException
    case deleteExceptions

    public var stableId: InputDataEntryId {
        switch self {
        case .show:
            return .general(_id_enabled)
        case .preview:
            return .general(_id_previews)
        case .sound:
            return .general(_id_sound)
        case .addException:
            return .custom(_id_add_exception)
        case .deleteExceptions:
            return .general(_id_delete_all)
        }
    }

    public func isEqual(to other: ItemListItemTag) -> Bool {
        if let other = other as? NotificationCategoryEntryTag, self == other {
            return true
        } else {
            return false
        }
    }
}

private func exceptionStatus(_ exception: NotificationException, now: Int32) -> String {
    var components: [String] = []
    let settings = exception.settings
    switch settings.muteState {
    case .unmuted:
        components.append(strings().notificationSettingsExceptionsAlwaysOn)
    case let .muted(until):
        if until >= Int32.max - 1 {
            return strings().notificationSettingsExceptionsAlwaysOff
        } else if until > now {
            components.append(strings().notificationSettingsExceptionsMutedUntil(stringForMediumDate(timestamp: until)))
        } else {
            components.append(strings().notificationSettingsExceptionsAlwaysOn)
        }
    case .default:
        break
    }
    if settings.messageSound != .default {
        components.append(strings().notificationSettingsExceptionsCustomSound)
    }
    switch settings.displayPreviews {
    case .show:
        components.append(strings().notificationSettingsExceptionsShowPreview)
    case .hide:
        components.append(strings().notificationSettingsExceptionsHidePreview)
    case .default:
        break
    }
    return components.joined(separator: ", ")
}

private struct ExceptionRow : Equatable {
    let exception: NotificationException
    let status: String
    let viewType: GeneralViewType
}

private func entries(_ state: State, category: NotificationSettingsCategory, arguments: Arguments) -> [InputDataEntry] {
    var entries:[InputDataEntry] = []

    var sectionId:Int32 = 0
    var index: Int32 = 0

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    let messageSettings = category.messageSettings(state.settings)

    entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_enabled, data: .init(name: strings().notificationSettingsCategoryShowNotifications, color: theme.colors.text, type: .switchable(messageSettings.enabled), viewType: .singleItem, action: arguments.toggleEnabled)))
    index += 1

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    if messageSettings.enabled || !state.exceptions.isEmpty {
        entries.append(.desc(sectionId: sectionId, index: index, text: .plain(strings().notificationSettingsOptions), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
        index += 1

        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_previews, data: .init(name: strings().notificationSettingsMessagesPreview, color: theme.colors.text, type: .switchable(messageSettings.displayPreviews), viewType: .firstItem, action: arguments.togglePreviews)))
        index += 1

        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_sound, data: .init(name: strings().notificationSettingsCategorySound, color: theme.colors.text, type: .nextContext(localizedPeerNotificationSoundString(sound: effectiveCategorySound(messageSettings.sound), default: state.inAppTone, list: state.soundList?.sounds)), viewType: .lastItem, action: arguments.openSound)))
        index += 1

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
    }

    entries.append(.desc(sectionId: sectionId, index: index, text: .plain(strings().notificationSettingsExceptionsHeader), data: .init(color: theme.colors.listGrayText, viewType: .textTopItem)))
    index += 1

    let isLoading = !state.loaded && state.exceptions.isEmpty

    let addViewType: GeneralViewType = state.exceptions.isEmpty && !isLoading ? .singleItem : .firstItem
    entries.append(.custom(sectionId: sectionId, index: index, value: .none, identifier: _id_add_exception, equatable: .init(addViewType), comparable: nil, item: { initialSize, stableId in
        return GeneralInteractedRowItem(initialSize, stableId: stableId, name: strings().notificationSettingsExceptionsAdd, nameStyle: blueActionButton, type: .none, viewType: addViewType, action: arguments.addException, thumb: GeneralThumbAdditional(thumb: theme.icons.peerInfoAddMember, textInset: 52, thumbInset: 5))
    }))
    index += 1

    if isLoading {
        entries.append(.custom(sectionId: sectionId, index: index, value: .none, identifier: _id_loading, equatable: nil, comparable: nil, item: { initialSize, stableId in
            return GeneralLoadingRowItem(initialSize, stableId: stableId, viewType: .lastItem)
        }))
        index += 1
    }

    let now = Int32(Date().timeIntervalSince1970)
    for (i, exception) in state.exceptions.enumerated() {
        let viewType: GeneralViewType = i == state.exceptions.count - 1 ? .lastItem : .innerItem
        let tuple = ExceptionRow(exception: exception, status: exceptionStatus(exception, now: now), viewType: viewType)
        entries.append(.custom(sectionId: sectionId, index: index, value: .none, identifier: _id_exception(exception.peer.id), equatable: .init(tuple), comparable: nil, item: { initialSize, stableId in
            return ShortPeerRowItem(initialSize, peer: tuple.exception.peer._asPeer(), account: arguments.context.account, context: arguments.context, stableId: stableId, height: 46, photoSize: NSMakeSize(32, 32), status: tuple.status.isEmpty ? nil : tuple.status, inset: NSEdgeInsets(left: 20, right: 20), viewType: tuple.viewType, action: {
                arguments.openPeer(tuple.exception.peer.id)
            }, contextMenuItems: {
                return .single(arguments.exceptionMenu(tuple.exception))
            }, menuOnAction: true)
        }))
        index += 1
    }

    entries.append(.sectionId(sectionId, type: .normal))
    sectionId += 1

    if !state.exceptions.isEmpty {
        entries.append(.general(sectionId: sectionId, index: index, value: .none, error: nil, identifier: _id_delete_all, data: .init(name: strings().notificationSettingsExceptionsDeleteAll, color: theme.colors.redUI, type: .none, viewType: .singleItem, action: arguments.deleteAll)))
        index += 1

        entries.append(.sectionId(sectionId, type: .normal))
        sectionId += 1
    }

    return entries
}

public func NotificationCategorySettingsController(context: any AccountContextProtocol, category: NotificationSettingsCategory, exceptionsContext: NotificationExceptionsContext? = nil, focusOnItemTag: NotificationCategoryEntryTag? = nil) -> InputDataController {

    let actionsDisposable = DisposableSet()

    let exceptionsContext = exceptionsContext ?? NotificationExceptionsContext(context: context)

    let initialState = State()

    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((State) -> State) -> Void = { f in
        statePromise.set(stateValue.modify (f))
    }

    let updateSettings:(@escaping (inout MessageNotificationSettings) -> Void) -> Void = { f in
        _ = updateGlobalNotificationSettingsInteractively(postbox: context.account.postbox, { settings in
            var settings = settings
            category.updateMessageSettings(&settings, f)
            return settings
        }).start()
    }

    let peerSound:(PeerId) -> Signal<PeerMessageSound, NoError> = { peerId in
        let key: PostboxViewKey = .peerNotificationSettings(peerIds: Set([peerId]))
        return context.account.postbox.combinedView(keys: [key]) |> map { view in
            return (((view.views[key] as? PeerNotificationSettingsView)?.notificationSettings[peerId] as? TelegramPeerNotificationSettings) ?? .defaultSettings).messageSound
        }
    }

    let removeExceptions:([PeerId]) -> Void = { peerIds in
        exceptionsContext.remove(peerIds)
        _ = context.engine.peers.removeCustomNotificationSettings(peerIds: peerIds).start()
    }

    let arguments = Arguments(context: context, toggleEnabled: {
        updateSettings { settings in
            settings.enabled = !settings.enabled
        }
    }, togglePreviews: {
        updateSettings { settings in
            settings.displayPreviews = !settings.displayPreviews
        }
    }, openSound: {
        let tone: Signal<PeerMessageSound, NoError> = globalNotificationSettings(postbox: context.account.postbox) |> map { settings in
            return effectiveCategorySound(category.messageSettings(settings).sound)
        }
        context.bindings.rootNavigation().push(NotificationSoundController(context: context, tone: tone, updateTone: { sound in
            updateSettings { settings in
                settings.sound = sound
            }
        }))
    }, addException: {
        let excludePeerIds = stateValue.with { $0.exceptions.map { $0.peer.id } }
        let behavior = SelectChatsBehavior(settings: category.selectSettings, excludePeerIds: excludePeerIds, limit: 1)
        _ = (selectModalPeers(window: context.window, context: context, title: strings().notificationSettingsExceptionsAdd, behavior: behavior) |> deliverOnMainQueue).start(next: { peerIds in
            guard let peerId = peerIds.first else {
                return
            }
            let settings = category.messageSettings(stateValue.with { $0.settings })
            exceptionsContext.add(peerId)
            _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: settings.enabled ? Int32.max : 0).start()
        })
    }, deleteAll: {
        verifyAlert_button(for: context.window, information: strings().notificationSettingsExceptionsDeleteAllConfirm, ok: strings().notificationSettingsExceptionsDeleteAll, successHandler: { _ in
            removeExceptions(stateValue.with { $0.exceptions.map { $0.peer.id } })
        })
    }, openPeer: { peerId in
        BlockedPeersHooks.shared.openPeerInfo(context.bindings.rootNavigation(), context, peerId)
    }, exceptionMenu: { exception in
        let peerId = exception.peer.id
        var items: [ContextMenuItem] = []

        let now = Int32(Date().timeIntervalSince1970)
        if exception.isEffectivelyMuted(now: now) {
            items.append(ContextMenuItem(strings().chatListContextUnmute, handler: {
                _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 0).start()
            }, itemImage: MenuAnimation.menu_unmuted.value))
        } else {
            let mute = ContextMenuItem(strings().chatListContextMute, itemImage: MenuAnimation.menu_mute.value)
            let submenu = ContextMenu()
            submenu.addItem(ContextMenuItem(strings().chatListMute1Hour, handler: {
                _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 60 * 60 * 1).start()
            }, itemImage: MenuAnimation.menu_mute_for_1_hour.value))
            submenu.addItem(ContextMenuItem(strings().chatListMute8Hours, handler: {
                _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 60 * 60 * 8).start()
            }, itemImage: MenuAnimation.menu_mute_for_1_hour.value))
            submenu.addItem(ContextMenuItem(strings().chatListMute3Days, handler: {
                _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: 60 * 60 * 24 * 3).start()
            }, itemImage: MenuAnimation.menu_mute_for_2_days.value))
            submenu.addItem(ContextSeparatorItem())
            submenu.addItem(ContextMenuItem(strings().chatListMuteUntil, handler: {
                FeatureNavigationHooks.shared.selectDate(context, context.window, nil, nil, .date(title: strings().chatListMuteUntilTitle, doneTitle: strings().chatListMuteUntilOK), { date, _ in
                    let interval = Int32(date.timeIntervalSince1970 - Date().timeIntervalSince1970)
                    if interval > 0 {
                        _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: interval).start()
                    }
                })
            }, itemImage: MenuAnimation.menu_schedule_message.value))
            submenu.addItem(ContextMenuItem(strings().chatListMuteForever, handler: {
                _ = context.engine.peers.updatePeerMuteSetting(peerId: peerId, threadId: nil, muteInterval: Int32.max).start()
            }, itemImage: MenuAnimation.menu_mute.value))
            mute.submenu = submenu
            items.append(mute)
        }

        let showPreview: Bool
        switch exception.settings.displayPreviews {
        case .show:
            showPreview = true
        case .hide:
            showPreview = false
        case .default:
            showPreview = category.messageSettings(stateValue.with { $0.settings }).displayPreviews
        }
        items.append(ContextMenuItem(showPreview ? strings().notificationSettingsExceptionsHidePreview : strings().notificationSettingsExceptionsShowPreview, handler: {
            _ = context.engine.peers.updatePeerDisplayPreviewsSetting(peerId: peerId, threadId: nil, displayPreviews: showPreview ? .hide : .show).start()
        }, itemImage: MenuAnimation.menu_eye.value))

        items.append(ContextMenuItem(strings().notificationSettingsCategorySound, handler: {
            context.bindings.rootNavigation().push(NotificationSoundController(context: context, tone: peerSound(peerId), updateTone: { sound in
                _ = context.engine.peers.updatePeerNotificationSoundInteractive(peerId: peerId, threadId: nil, sound: sound).start()
            }))
        }, itemImage: MenuAnimation.menu_music.value))

        items.append(ContextSeparatorItem())
        items.append(ContextMenuItem(strings().notificationSettingsExceptionsRemove, handler: {
            removeExceptions([peerId])
        }, itemMode: .destruct, itemImage: MenuAnimation.menu_delete.value))

        return items
    })

    actionsDisposable.add(combineLatest(queue: .mainQueue(), globalNotificationSettings(postbox: context.account.postbox), appNotificationSettings(accountManager: context.sharedContext.accountManager), context.engine.peers.notificationSoundList(), exceptionsContext.exceptions(for: category), exceptionsContext.loaded).start(next: { settings, inAppSettings, soundList, exceptions, loaded in
        updateState { current in
            var current = current
            current.settings = settings
            current.inAppTone = inAppSettings.tone
            current.soundList = soundList
            current.exceptions = exceptions
            current.loaded = loaded
            current.settingsLoaded = true
            return current
        }
    }))

    let signal = statePromise.get() |> filter { $0.settingsLoaded } |> deliverOnPrepareQueue |> map { state in
        return InputDataSignalValue(entries: entries(state, category: category, arguments: arguments))
    }

    let controller = InputDataController(dataSignal: signal, title: category.title, removeAfterDisappear: false, hasDone: false, identifier: "notification-category-settings")

    let pendingFocus = Atomic<Bool>(value: focusOnItemTag != nil)
    controller.afterTransaction = { controller in
        guard let focusOnItemTag = focusOnItemTag, controller.genericView.tableView.item(stableId: focusOnItemTag.stableId) != nil, pendingFocus.swap(false) else {
            return
        }
        controller.genericView.tableView.scroll(to: .center(id: focusOnItemTag.stableId, innerId: nil, animated: true, focus: .init(focus: true), inset: 0), inset: NSEdgeInsets())
    }

    controller.onDeinit = {
        actionsDisposable.dispose()
    }

    return controller
}
