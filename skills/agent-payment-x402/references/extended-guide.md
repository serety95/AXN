# agent-payment-x402 — Extended Reference

        reason: "payment_replayed",
        message: "This payment authorization was already presented.",
      };
    } catch {
      // Return, don't throw: the resource server logs and skips a hook that
      // throws, which would run the handler unguarded.
      if (FAIL_CLOSED) {
        // A write that timed out can still land. This request is refused and
        // the handler never runs, so release a late claim, or the retry
        // would be refused as a replay of work that never happened.
        set?.then((reply) => (reply === "OK" && claim ? redis.del(claim.key) : 0)).catch(() => {});
        return { abort: true, reason: "claim_unavailable", message: "Retry shortly." };
      }
    }
  });

const app = express();
app.use(express.json());
app.use(
  paymentMiddleware(
    {
      "POST /report": {
        accepts: [{ scheme: "exact", price: "$0.01", network: "eip155:8453", payTo: process.env.PAY_TO! }],
      },
    },
    resourceServer,
  ),
);
app.post("/report", async (req, res, next) => {
  try {
    res.json(await buildReport(req.body));
  } catch (error) {
    // Keep the claim: a failed handler may already have performed side effects.
    next(error);
  }
});
```

Any store with an atomic conditional insert works: DynamoDB `PutItem` with `attribute_not_exists`, or a unique index in Postgres. Two things the guard does not decide for you. If the store is down, `FAIL_CLOSED` keeps the once-per-authorization guarantee at the cost of availability; failing open keeps the route up but lets every copy run the handler until the store recovers, so use it only for idempotent handlers. And `payment_replayed` means the authorization was presented before, not that the first attempt failed: if the client lost the first response, the work may have run and the payment may have settled, so it should reconcile the original request before signing a new authorization. This closes duplicate copies of one authorization only. A payer who invalidates the payment between verify and settle (for example by moving the funds) still gets one handler run; for expensive routes, hold funds before doing the work.

**Discovery.** Facilitators that implement the x402 bazaar extension expose a `/discovery/resources` endpoint — query the CDP catalog at `https://api.cdp.coinbase.com/platform/v2/x402/discovery/resources` and the PayAI catalog at `https://facilitator.payai.network/discovery/resources`. Roundhouse publishes an indexed service directory (not the bazaar `/discovery/resources` path) at `https://api.roundhouseai.io/v0/endpoints` and `https://roundhouseai.io/services.json`, plus ERC-8004 agent reads under `/v0/agents`. For Solana-payable services there is also [pay.sh](https://pay.sh), the Solana Foundation's curated catalog.

## Examples

### Budget enforcement in an MCP client

When building an orchestrator that calls the agentpay MCP server, enforce budgets before dispatching paid tool calls.

> **Prerequisites**: Install the package before adding the MCP config — `npx` without `-y` will prompt for confirmation in non-interactive environments, causing the server to hang: `npm install -g agentwallet-sdk@6.0.0`

```typescript
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";

async function main() {
  // 1. Validate credentials before constructing the transport.
  //    A missing key must fail immediately — never let the subprocess start without auth.
  const walletKey = process.env.WALLET_PRIVATE_KEY;
  if (!walletKey) {
    throw new Error("WALLET_PRIVATE_KEY is not set — refusing to start payment server");
  }

  // Connect to the agentpay MCP server via stdio transport.
  // Whitelist only the env vars the server needs — never forward all of process.env
  // to a third-party subprocess that manages private keys.
  const transport = new StdioClientTransport({
    command: "npx",
    args: ["agentwallet-sdk@6.0.0"],
    env: {
      PATH: process.env.PATH ?? "",
      NODE_ENV: process.env.NODE_ENV ?? "production",
      WALLET_PRIVATE_KEY: walletKey,
    },
  });
  const agentpay = new Client({ name: "orchestrator", version: "1.0.0" });
  await agentpay.connect(transport);

  // 2. Set spending policy before delegating to the agent.
  //    Always verify success — a silent failure means no controls are active.
  const policyResult = await agentpay.callTool({
    name: "set_policy",
    arguments: {
      per_task_budget: 0.50,
      per_session_budget: 5.00,
      allowlisted_recipients: ["api.example.com"],
    },
  });
  if (policyResult.isError) {
    throw new Error(
      `Failed to set spending policy — do not delegate: ${JSON.stringify(policyResult.content)}`
    );
  }

  // 3. Use preToolCheck before any paid action
  await preToolCheck(agentpay, 0.01);
}

// Pre-tool hook: fail-closed budget enforcement with four distinct error paths.
async function preToolCheck(agentpay: Client, apiCost: number): Promise<void> {
  // Path 1: Reject invalid input (NaN/Infinity bypass the < comparison)
  if (!Number.isFinite(apiCost) || apiCost < 0) {
    throw new Error(`Invalid apiCost: ${apiCost} — action blocked`);
  }

  // Path 2: Transport/connectivity failure
  let result;
  try {
    result = await agentpay.callTool({ name: "check_spending" });
  } catch (err) {
    throw new Error(`Payment service unreachable — action blocked: ${err}`);
  }

  // Path 3: Tool returned an error (e.g., auth failure, wallet not initialised)
  if (result.isError) {
    throw new Error(
      `check_spending failed — action blocked: ${JSON.stringify(result.content)}`
    );
  }

  // Path 4: Parse and validate the response shape
  let remaining: number;
  try {
    const parsed = JSON.parse(
      (result.content as Array<{ text: string }>)[0].text
    );
    if (!Number.isFinite(parsed?.remaining)) {
      throw new TypeError("missing or non-finite 'remaining' field");
    }
    remaining = parsed.remaining;
  } catch (err) {
    throw new Error(
      `check_spending returned unexpected format — action blocked: ${err}`
    );
  }

  // Path 5: Budget exceeded
  if (remaining < apiCost) {
    throw new Error(
      `Budget exceeded: need $${apiCost} but only $${remaining} remaining`
    );
  }
}

main().catch((err) => {
  console.error(err);
  process.exitCode = 1;
});
```

## Best Practices

- **Set budgets before delegation**: When spawning sub-agents, attach a SpendingPolicy via your orchestration layer. Never give an agent unlimited spend.
- **Pin your dependencies**: Always specify an exact version in your MCP config (e.g., `agentwallet-sdk@6.0.0`). Verify package integrity before deploying to production.
- **Audit trails**: Use `list_transactions` in post-task hooks to log what was spent and why.
- **Fail closed**: If the payment tool is unreachable, block the paid action — don't fall back to unmetered access.
- **Pair with security-review**: Payment tools are high-privilege. Apply the same scrutiny as shell access.
- **Test with testnets first**: Use Base Sepolia for development; switch to Base mainnet for production. On Solana, develop against Solana devnet (`solana:EtWTRABZaYq6iMfeYKouRu166VU2xqa1`) and the free x402.org facilitator before moving to a production facilitator on mainnet.
- **On Solana, fund USDC not SOL**: The exact-SVM scheme makes the facilitator the transaction fee payer, so a SOL-less wallet still pays. Verify each challenge's `asset` against the expected USDC mint (mainnet `EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v`, devnet `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU`) before signing — a wrapped client that pays any asset is a hole in your budget.

## Production Reference

- **npm**: [`agentwallet-sdk`](https://www.npmjs.com/package/agentwallet-sdk)
- **Merged into NVIDIA NeMo Agent Toolkit**: [PR #17](https://github.com/NVIDIA/NeMo-Agent-Toolkit-Examples/pull/17) — x402 payment tool for NVIDIA's agent examples
- **Protocol spec**: [x402.org](https://x402.org)
- **OKX Payments SDKs**: [`okx/payments`](https://github.com/okx/payments) — TypeScript, Go, Rust, and Java seller integrations for X Layer x402
- **OKX Agent Payments Protocol skill**: [`okx/onchainos-skills`](https://github.com/okx/onchainos-skills/tree/main/skills/okx-agent-payments-protocol)
- **OKX Payments overview**: [web3.okx.com/onchainos/dev-docs/payments/overview](https://web3.okx.com/onchainos/dev-docs/payments/overview)
- **Upstream x402 monorepo**: [`x402-foundation/x402`](https://github.com/x402-foundation/x402) — TypeScript, Python, and Go implementations plus maintained client and server examples
- **x402 docs**: [docs.x402.org](https://docs.x402.org); production facilitator list at [docs.x402.org/dev-tools/facilitators](https://docs.x402.org/dev-tools/facilitators)
- **`@x402` packages**: [npmjs.com/org/x402](https://www.npmjs.com/org/x402) — `@x402/fetch`, `@x402/axios`, `@x402/express`, `@x402/hono`, `@x402/next`, `@x402/fastify`, `@x402/evm`, `@x402/svm`
- **Facilitators**: [self-facilitation example](https://github.com/x402-foundation/x402/tree/main/examples/typescript/servers/self-facilitation) (no third party), [x402.org facilitator](https://x402.org/facilitator) (testnet default), and the maintained [production list](https://docs.x402.org/dev-tools/facilitators)
- **Discovery**: CDP and PayAI bazaars at `/discovery/resources`; Roundhouse directory at `/v0/endpoints` and `services.json`; [pay.sh](https://pay.sh) for Solana-payable services
