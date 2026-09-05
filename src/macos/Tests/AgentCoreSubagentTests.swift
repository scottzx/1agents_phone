//
//  AgentCoreSubagentTests.swift
//  MinisDesktopPackageTests
//

import XCTest
@testable import MinisAppleDomain

final class AgentCoreSubagentTests: XCTestCase {

    // MARK: - Config Tests

    func testConfigDefaultsAndCodableRoundTrip() throws {
        let config = AgentCoreConfig.default
        XCTAssertEqual(config.region, "us-west-2")
        XCTAssertEqual(config.gatewayId, "opc-copilot-gateway-dd2yv3lwbo")
        XCTAssertEqual(config.harnessId, "opc_ops_copilot-qD0Xj1JRV6")
        XCTAssertEqual(config.defaultActorId, "founder-general")
        XCTAssertTrue(config.isEnabled)

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(AgentCoreConfig.self, from: data)
        XCTAssertEqual(config, decoded)
    }

    // MARK: - Parser Tests

    func testParserDetectsCedarPolicyInterception() {
        let largeAmountOutput = "Cedar Engine Error: Action intercepted by forbid_large_amount policy"
        let decision1 = AgentCoreParser.parseDecision(from: largeAmountOutput)
        XCTAssertEqual(decision1.tier, .escalate)
        XCTAssertEqual(decision1.policyRule, "forbid_large_amount")
        XCTAssertTrue(decision1.summary.contains("创始人审批"))

        let newClientOutput = "Action intercepted by forbid_new_counterparty: 新客户首单"
        let decision2 = AgentCoreParser.parseDecision(from: newClientOutput)
        XCTAssertEqual(decision2.tier, .escalate)
        XCTAssertEqual(decision2.policyRule, "forbid_new_counterparty")

        let overdueOutput = "Gateway rejected: forbid_counterparty_overdue 对手方有逾期记录"
        let decision3 = AgentCoreParser.parseDecision(from: overdueOutput)
        XCTAssertEqual(decision3.tier, .refuse)
        XCTAssertEqual(decision3.policyRule, "forbid_counterparty_overdue")
    }

    func testParserDetectsExplicitTiers() {
        let autoText = """
        [auto]
        审核通过，该续约合同符合标准费率规范。
        [档位=auto]
        """
        let decisionAuto = AgentCoreParser.parseDecision(from: autoText)
        XCTAssertEqual(decisionAuto.tier, .auto)

        let escalateText = """
        [escalate]
        【事实情况】: 老客户要求七折优惠。
        【需决策事项】: 是否同意超出常规折扣上限的特批？
        """
        let decisionEscalate = AgentCoreParser.parseDecision(from: escalateText)
        XCTAssertEqual(decisionEscalate.tier, .escalate)

        let refuseText = "[refuse] 无法处理逾期客户的新增发货申请。"
        let decisionRefuse = AgentCoreParser.parseDecision(from: refuseText)
        XCTAssertEqual(decisionRefuse.tier, .refuse)

        let normalText = "这是一段普通的分析文本，没有特殊的档位标注。"
        let decisionNormal = AgentCoreParser.parseDecision(from: normalText)
        XCTAssertEqual(decisionNormal.tier, .unknown)
    }

    // MARK: - Routing Tests

    func testTaskRoutingDistinguishesBusinessFromDeviceTasks() {
        XCTAssertTrue(AgentCoreTaskRouting.isCloudTask("请帮我核算一下这个供应商给的最新报价合同"))
        XCTAssertTrue(AgentCoreTaskRouting.isCloudTask("核对一下回声传媒上个月的账单和对账单差异"))
        XCTAssertTrue(AgentCoreTaskRouting.isCloudTask("查询一下我们当前的定价策略和折扣上限"))
        XCTAssertTrue(AgentCoreTaskRouting.isCloudTask("Run reconciliation skill on agentcore"))

        XCTAssertFalse(AgentCoreTaskRouting.isCloudTask("查看当前工作目录下的所有文件"))
        XCTAssertFalse(AgentCoreTaskRouting.isCloudTask("打开浏览器抓取网页"))
        XCTAssertFalse(AgentCoreTaskRouting.isCloudTask("ls -la /var/minis/shared"))
    }

    // MARK: - Transport Tests

    func testMockTransportInvocation() async throws {
        let mock = MockAgentCoreTransport { prompt, actor in
            return "[escalate] 拦截提示: \(actor ?? "none") - \(prompt)"
        }

        let output = try await mock.invoke(
            prompt: "测试核价",
            actorId: "CLIENT-ABC",
            gatewayId: "gw-1",
            harnessId: "harness-1"
        )

        XCTAssertTrue(output.contains("CLIENT-ABC"))
        XCTAssertTrue(output.contains("测试核价"))

        let decision = AgentCoreParser.parseDecision(from: output)
        XCTAssertEqual(decision.tier, .escalate)
    }

    // MARK: - Approval Request Tests

    func testApprovalRequestModel() throws {
        var req = SubagentApprovalRequest(
            taskId: "ac_test_123",
            title: "续约大额审批",
            summary: "金额超限，网关 Cedar 策略已拦截",
            policyRule: "forbid_large_amount",
            reason: "金额超出 200,000 元阈值"
        )
        XCTAssertEqual(req.status, .pending)
        XCTAssertNil(req.feedback)

        req.status = .approved
        req.feedback = "同意特批，请归档"
        req.resolvedAt = Date()

        let data = try JSONEncoder().encode(req)
        let decoded = try JSONDecoder().decode(SubagentApprovalRequest.self, from: data)
        XCTAssertEqual(decoded.taskId, "ac_test_123")
        XCTAssertEqual(decoded.status, .approved)
        XCTAssertEqual(decoded.policyRule, "forbid_large_amount")
        XCTAssertEqual(decoded.feedback, "同意特批，请归档")
    }
}
