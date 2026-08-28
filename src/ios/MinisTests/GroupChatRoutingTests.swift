#if DEBUG
import XCTest

/// Routing and projection tests for group chat.
///
/// Everything under test here is a pure function over values, which is the
/// whole reason GroupMentionRouter and GroupChatPrompt are written that way:
/// the rules that decide who speaks are the part most likely to be quietly
/// broken by a later change, and they are also the part that would otherwise
/// need a model call, a database and a device to exercise.
final class GroupChatRoutingTests: XCTestCase {

    // MARK: - Fixtures

    private func member(
        _ id: String,
        _ name: String,
        title: String = "",
        summary: String = "",
        slot: Int = 0
    ) -> GroupMember {
        GroupMember(id: id, name: name, title: title, emoji: "🙂",
                    accentColor: "#5B8DEF", summary: summary, slot: slot)
    }

    /// The DEMO_PRD roundtable cast, which is also the awkward case: Chinese
    /// names with no word separators.
    private lazy var market = member("a-market", "市场专家", title: "市场分析师", slot: 0)
    private lazy var product = member("a-product", "产品经理", title: "产品", slot: 1)
    private lazy var tech = member("a-tech", "技术负责人", title: "技术", slot: 2)
    private lazy var host = member("a-host", "主持人", title: "主持", slot: 3)
    private var cast: [GroupMember] { [market, product, tech, host] }

    // MARK: - Handles

    func testHandlesCoverNameVariantsAndTitle() {
        let ann = member("a-ann", "Ann Lee", title: "Research")
        let handles = GroupMentionRouter.handles(for: ann)
        XCTAssertEqual(Set(handles), ["ann lee", "annlee", "ann", "research"])
    }

    func testHandlesDeduplicateAndDropEmptyTitle() {
        XCTAssertEqual(GroupMentionRouter.handles(for: market), ["市场专家", "市场分析师"])
    }

    // MARK: - Token format

    func testTokenIsTheCanonicalMentionForm() {
        XCTAssertEqual(GroupMentionRouter.token(for: market.id), "<@a-market>")
        XCTAssertEqual(GroupMentionRouter.everyoneToken, "<@everyone>")
    }

    func testTokenMentionRoutesByIdNotByName() {
        let scan = GroupMentionRouter.parseMentions(
            in: "这块 \(GroupMentionRouter.token(for: tech.id)) 更清楚", members: cast)
        XCTAssertEqual(scan.memberIds, [tech.id])
        XCTAssertFalse(scan.usedLooseNameMatch, "token 命中不该走名字兜底")
    }

    func testTokenSurvivesARename() {
        // The whole point of storing an id: the stored message does not change
        // and it still reaches the same agent.
        let stored = "麻烦 \(GroupMentionRouter.token(for: market.id)) 看一下"
        let renamed = member("a-market", "市场组", title: "市场分析师", slot: 0)
        let roster = [renamed, product, tech, host]
        XCTAssertEqual(GroupMentionRouter.parseMentions(in: stored, members: roster).memberIds,
                       [renamed.id])
        XCTAssertEqual(GroupMentionRouter.render(stored, members: roster),
                       "麻烦 @市场组 看一下")
    }

    func testTokenForSomeoneOutsideTheRoomAddressesNobody() {
        // Never guess at the nearest member — a mention either reaches the
        // right agent or nobody.
        let scan = GroupMentionRouter.parseMentions(in: "<@a-stranger> 看看", members: cast)
        XCTAssertTrue(scan.memberIds.isEmpty)
        XCTAssertFalse(scan.isEveryone)
    }

    func testEveryoneToken() {
        let scan = GroupMentionRouter.parseMentions(in: "<@everyone> 都说说", members: cast)
        XCTAssertTrue(scan.isEveryone)
        XCTAssertFalse(scan.usedLooseNameMatch)
    }

    func testLabelledTokenIsTolerated() {
        // Slack writes `<@U123|name>`; a model that imitates it is not punished.
        let scan = GroupMentionRouter.parseMentions(in: "<@a-tech|技术负责人> 看看", members: cast)
        XCTAssertEqual(scan.memberIds, [tech.id])
    }

    // MARK: - Encode / render

    func testEncodeTurnsTypedNamesIntoTokens() {
        XCTAssertEqual(
            GroupMentionRouter.encode("@市场专家 和 @技术负责人 说一下", members: cast),
            "<@a-market> 和 <@a-tech> 说一下"
        )
    }

    func testEncodeHandlesEveryoneAndLeavesProseAlone() {
        XCTAssertEqual(GroupMentionRouter.encode("@所有人 说说", members: cast), "<@everyone> 说说")
        XCTAssertEqual(GroupMentionRouter.encode("市场专家怎么看", members: cast), "市场专家怎么看")
    }

    func testEncodeIsIdempotent() {
        let once = GroupMentionRouter.encode("@产品经理 你说", members: cast)
        XCTAssertEqual(GroupMentionRouter.encode(once, members: cast), once)
    }

    func testRenderIsTheInverseForDisplay() {
        let canonical = GroupMentionRouter.encode("@市场专家 @所有人 看看", members: cast)
        XCTAssertEqual(GroupMentionRouter.render(canonical, members: cast), "@市场专家 @所有人 看看")
    }

    func testRenderNamesADepartedMember() {
        XCTAssertEqual(
            GroupMentionRouter.render("问过 <@a-gone> 了", members: cast),
            "问过 @已退出的成员 了"
        )
    }

    // MARK: - Mention matching (name fallback)

    func testChineseMentionMatchesWithNoTrailingSeparator() {
        // The reason grok's `/[a-z0-9]/` trailing-boundary rule could not be
        // copied verbatim: Chinese does not put a space after a mention, so
        // requiring a non-word character here would miss every real message.
        let scan = GroupMentionRouter.parseMentions(in: "@技术负责人你怎么看", members: cast)
        XCTAssertEqual(scan.memberIds, [tech.id])
        XCTAssertFalse(scan.isEveryone)
        XCTAssertTrue(scan.usedLooseNameMatch, "按名字命中要被标记出来")
    }

    func testTokenWinsWhenBothFormsAppear() {
        let scan = GroupMentionRouter.parseMentions(
            in: "\(GroupMentionRouter.token(for: tech.id)) 你说，@市场专家 也补一句", members: cast)
        XCTAssertEqual(scan.memberIds, [market.id, tech.id])
        XCTAssertTrue(scan.usedLooseNameMatch)
    }

    func testLongerChineseHandleWinsOverShorterPrefix() {
        let ming = member("a-ming", "小明")
        let mingming = member("a-mingming", "小明明")
        let scan = GroupMentionRouter.parseMentions(in: "@小明明 来看看", members: [ming, mingming])
        XCTAssertEqual(scan.memberIds, [mingming.id], "短 handle 不能吃掉更长 handle 已经匹配的文本")
    }

    func testASCIIHandleStillRequiresTrailingBoundary() {
        let ann = member("a-ann", "Ann")
        let anna = member("a-anna", "Anna")
        XCTAssertEqual(GroupMentionRouter.parseMentions(in: "@anna hi", members: [ann, anna]).memberIds,
                       [anna.id])
        XCTAssertEqual(GroupMentionRouter.parseMentions(in: "@ann hi", members: [ann, anna]).memberIds,
                       [ann.id])
    }

    func testLeadingBoundaryRejectsEmailLikeText() {
        let ann = member("a-ann", "Ann")
        XCTAssertTrue(GroupMentionRouter.parseMentions(in: "mail me at foo@ann.com", members: [ann]).memberIds.isEmpty)
    }

    func testEveryoneTokens() {
        for text in ["@所有人 都说说", "@全体 注意", "@everyone please", "@all now"] {
            XCTAssertTrue(GroupMentionRouter.parseMentions(in: text, members: cast).isEveryone, text)
        }
        XCTAssertFalse(GroupMentionRouter.parseMentions(in: "@allow 一下", members: cast).isEveryone)
    }

    func testMentionedIdsComeBackInRosterOrderNotTextOrder() {
        let scan = GroupMentionRouter.parseMentions(in: "@技术负责人 和 @市场专家 说一下", members: cast)
        XCTAssertEqual(scan.memberIds, [market.id, tech.id])
    }

    // MARK: - resolveResponders — user messages

    func testUserMentionEveryoneWakesEverybody() {
        let history: [GroupMessage] = [.user("@所有人 都说说")]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: history, history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, cast.map(\.id))
        XCTAssertEqual(result.reason, .everyone)
    }

    func testUserNamedMentionWakesOnlyThatMember() {
        let history: [GroupMessage] = [.user("@产品经理 你先说")]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: history, history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [product.id])
        XCTAssertEqual(result.reason, .mentioned)
    }

    func testUnaddressedUserMessageContinuesWithLastSpeaker() {
        let trigger = GroupMessage.user("那成本呢？")
        let history: [GroupMessage] = [
            .user("@技术负责人 先说"),
            .member(tech.id, "延迟是关键。"),
            trigger,
        ]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [trigger], history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [tech.id])
        XCTAssertEqual(result.reason, .lastSpeaker)
    }

    func testUnaddressedUserMessageFallsBackToOwnerWhenNobodyHasSpoken() {
        let history: [GroupMessage] = [.user("我们开始吧")]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: history, history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [host.id])
        XCTAssertEqual(result.reason, .owner)
    }

    func testUnaddressedUserMessageFallsBackToFirstMemberWithNoOwner() {
        let history: [GroupMessage] = [.user("我们开始吧")]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: history, history: history, ownerAgentId: nil)
        XCTAssertEqual(result.responderIds, [market.id])
        XCTAssertEqual(result.reason, .firstMember)
    }

    // MARK: - resolveResponders — member messages

    func testMemberMessageWithoutMentionWakesNobody() {
        // The rule that makes a room able to fall silent: agents must address
        // each other explicitly, so an ordinary answer ends the exchange.
        let reply = GroupMessage.member(tech.id, "延迟是关键，别的都好办。")
        let history: [GroupMessage] = [.user("@技术负责人 说说"), reply]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [reply], history: history, ownerAgentId: host.id)
        XCTAssertTrue(result.responderIds.isEmpty)
        XCTAssertEqual(result.reason, .none)
    }

    func testMemberMentionWakesOnlyTheNamedPeer() {
        let reply = GroupMessage.member(tech.id, "这点得问 @市场专家")
        let history: [GroupMessage] = [.user("说说"), reply]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [reply], history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [market.id])
    }

    func testNonOwnerEveryoneIsDowngradedButNamedMentionsSurvive() {
        let reply = GroupMessage.member(tech.id, "@所有人 都来看看，尤其 @产品经理")
        let history: [GroupMessage] = [.user("说说"), reply]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [reply], history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [product.id])
        XCTAssertEqual(result.downgradedEveryoneBy, [tech.id])
    }

    func testOwnerMayAddressEveryone() {
        let call = GroupMessage.member(host.id, "@所有人 依次说")
        let history: [GroupMessage] = [.user("开始"), call]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [call], history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [market.id, product.id, tech.id],
                       "群主自己不该被自己叫醒")
        XCTAssertTrue(result.downgradedEveryoneBy.isEmpty)
    }

    func testSenderNeverAnswersItself() {
        let reply = GroupMessage.member(tech.id, "@技术负责人 再想想")
        let history: [GroupMessage] = [.user("说说"), reply]
        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [reply], history: history, ownerAgentId: host.id)
        XCTAssertTrue(result.responderIds.isEmpty)
    }

    // MARK: - Turn taking

    func testOrderRoundSpeakersRotates() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(GroupMentionRouter.orderRoundSpeakers(ids, round: 0), ["a", "b", "c"])
        XCTAssertEqual(GroupMentionRouter.orderRoundSpeakers(ids, round: 1), ["b", "c", "a"])
        XCTAssertEqual(GroupMentionRouter.orderRoundSpeakers(ids, round: 2), ["c", "a", "b"])
        XCTAssertEqual(GroupMentionRouter.orderRoundSpeakers(ids, round: 3), ["a", "b", "c"])
        XCTAssertEqual(GroupMentionRouter.orderRoundSpeakers([String](), round: 2), [])
    }

    func testMessagesSinceMemberLastSpoke() {
        let history: [GroupMessage] = [
            .user("开始"),
            .member(market.id, "市场看法"),
            .member(product.id, "产品看法"),
            .member(tech.id, "技术看法"),
        ]
        XCTAssertEqual(
            GroupMentionRouter.messagesSinceMemberLastSpoke(history, memberId: market.id),
            [.member(product.id, "产品看法"), .member(tech.id, "技术看法")]
        )
        XCTAssertEqual(
            GroupMentionRouter.messagesSinceMemberLastSpoke(history, memberId: host.id).count,
            history.count,
            "没发过言的成员应该看到全部历史"
        )
    }

    func testPassDetection() {
        for text in ["(pass)", "pass", " PASS ", "（略过）", "跳过", ""] {
            XCTAssertTrue(GroupMentionRouter.isPass(text), text)
        }
        XCTAssertFalse(GroupMentionRouter.isPass("我觉得可以做"))
    }

    func testPotentialPassPrefixSuppressesEarlyBubble() {
        for prefix in ["", "(", "(p", "(pas", "(pass)", "略"] {
            XCTAssertTrue(GroupMentionRouter.isPotentialPassPrefix(prefix), prefix)
        }
        XCTAssertFalse(GroupMentionRouter.isPotentialPassPrefix("passable 的方案"))
        XCTAssertFalse(GroupMentionRouter.isPotentialPassPrefix("我"))
    }

    // MARK: - Round windows

    func testBroadcastDoesNotRepeatItselfOnTheNextRound() {
        // The reason the scan window is "this round's new messages" rather than
        // grok's "everything since the last user message": with a directed
        // policy, re-reading an already-answered @所有人 every round would keep
        // re-waking the whole room until the round cap ran out, instead of
        // letting it fall silent when nobody was addressed.
        let trigger = GroupMessage.user("@所有人 说说")
        var history: [GroupMessage] = [trigger]

        let round0 = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [trigger], history: history, ownerAgentId: host.id)
        XCTAssertEqual(round0.responderIds.count, cast.count)

        // Everyone answers, nobody hands off.
        let replies = cast.map { GroupMessage.member($0.id, "我的看法。") }
        history += replies

        let round1 = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: replies, history: history, ownerAgentId: host.id)
        XCTAssertTrue(round1.responderIds.isEmpty, "没人被 @，房间应该安静下来")
    }

    func testAHandoffMidRoundPullsInTheNamedPeerNextRound() {
        let trigger = GroupMessage.user("@市场专家 说说")
        var history: [GroupMessage] = [trigger]
        let reply = GroupMessage.member(market.id, "这块得 @技术负责人 来判断")
        history.append(reply)

        let next = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [reply], history: history, ownerAgentId: host.id)
        XCTAssertEqual(next.responderIds, [tech.id])
    }

    func testTwoUserMessagesInOneWindowAreBothRead() {
        // What happens when the user types again while the room is thinking:
        // the running loop takes both lines as one window.
        let first = GroupMessage.user("再想想")
        let second = GroupMessage.user("@产品经理 你说")
        let history: [GroupMessage] = [.user("开始"), .member(tech.id, "初步看法"), first, second]

        let result = GroupMentionRouter.resolveResponders(
            members: cast, newMessages: [first, second], history: history, ownerAgentId: host.id)
        XCTAssertEqual(result.responderIds, [product.id])
        XCTAssertEqual(result.reason, .mentioned)
    }

    // MARK: - Caps

    func testEveryoneAskingEveryoneStillTerminates() {
        // Simulates the worst case the caps exist for: every member ends every
        // turn by @-ing every other member. The orchestrator's loop shape is
        // reproduced here so the caps are asserted independently of it.
        var history: [GroupMessage] = [.user("@所有人 讨论一下")]
        var newMessages = history
        var total = 0
        var rounds = 0

        for round in 0..<GroupChatLimits.maxRounds {
            let result = GroupMentionRouter.resolveResponders(
                members: cast, newMessages: newMessages, history: history, ownerAgentId: host.id)
            if result.responderIds.isEmpty { break }
            rounds += 1
            var produced: [GroupMessage] = []
            for id in GroupMentionRouter.orderRoundSpeakers(result.responderIds, round: round) {
                guard total < GroupChatLimits.maxMemberTurns else { break }
                let everyoneElse = cast.filter { $0.id != id }.map { "@\($0.name)" }.joined(separator: " ")
                let message = GroupMessage.member(id, "我的看法。\(everyoneElse)")
                produced.append(message)
                history.append(message)
                total += 1
            }
            newMessages = produced
        }

        XCTAssertLessThanOrEqual(total, GroupChatLimits.maxMemberTurns)
        XCTAssertLessThanOrEqual(rounds, GroupChatLimits.maxRounds)
    }

    // MARK: - Projection

    func testTurnPromptMarksTheViewersOwnLines() {
        let history: [GroupMessage] = [
            .user("语音转文字 App 还值得做吗？"),
            .member(market.id, "赛道饱和。"),
            .member(tech.id, "延迟才是关键。"),
        ]
        let prompt = GroupChatPrompt.turnPrompt(
            member: tech,
            groupTitle: "产品圆桌",
            peers: [market, product, host],
            allMembers: cast,
            newMessages: history
        )
        XCTAssertTrue(prompt.hasPrefix("[群聊：「产品圆桌」 — 与 市场专家、产品经理、主持人 同在]"))
        XCTAssertTrue(prompt.contains("用户: 语音转文字 App 还值得做吗？"))
        XCTAssertTrue(prompt.contains("市场专家: 赛道饱和。"))
        XCTAssertTrue(prompt.contains("技术负责人 (你): 延迟才是关键。"),
                      "成员必须能在纯文本里认出哪几行是自己说的")
        XCTAssertTrue(GroupChatPrompt.isGroupTurnPrompt(prompt))
    }

    func testHistoryIsTruncatedToTheProjectionWindow() {
        let history = (0..<40).map { GroupMessage.member(market.id, "第 \($0) 条") }
        let text = GroupChatPrompt.formatHistory(history, viewerId: tech.id, members: cast)
        XCTAssertEqual(text.components(separatedBy: "\n").count, GroupChatLimits.promptHistoryLimit)
        XCTAssertTrue(text.contains("第 39 条"))
        XCTAssertFalse(text.contains("第 15 条"))
    }

    func testDepartedMemberStillRendersALine() {
        let text = GroupChatPrompt.formatLine(
            .member("gone", "我说过的话"), viewerId: tech.id, members: cast)
        XCTAssertEqual(text, "已退出的成员: 我说过的话")
    }

    func testMemberSystemBlockListsPeersAndOwnerRule() {
        let ownerBlock = GroupChatPrompt.memberSystemBlock(
            member: host, groupTitle: "产品圆桌", mode: .freeform, isOwner: true,
            peers: [market, product, tech])
        XCTAssertTrue(ownerBlock.contains(GroupMentionRouter.everyoneToken),
                      "群主要被告知招呼全体的确切写法")
        // The peer list is the ONLY place a member is shown the tokens it needs
        // in order to @ anyone, so every peer must appear there with one.
        for peer in [market, product, tech] {
            XCTAssertTrue(ownerBlock.contains(peer.name), peer.name)
            XCTAssertTrue(ownerBlock.contains(GroupMentionRouter.token(for: peer.id)), peer.id)
        }

        let memberBlock = GroupChatPrompt.memberSystemBlock(
            member: tech, groupTitle: "产品圆桌", mode: .freeform, isOwner: false,
            peers: [market, product, host])
        XCTAssertTrue(memberBlock.contains("只有群主能招呼所有人"))
        XCTAssertFalse(memberBlock.contains(GroupMentionRouter.everyoneToken),
                       "非群主不该被教会一个对它无效的写法")
    }
}
#endif
