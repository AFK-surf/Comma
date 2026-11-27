import assert from "node:assert/strict";
import test from "node:test";
import { compareDumps, compareRuns, renderMarkdown } from "./prompt-ab-compare.mjs";

test("compareDumps computes byte-identical flags and section deltas", () => {
  const base = {
    variants: [
      {
        name: "router_sandbox",
        chars: 50000,
        sha256: "aaa",
        sections: { prose_chars: 25000, tool_disclosure_chars: 18000, skills_chars: 7000 },
      },
      {
        name: "worker_triage",
        chars: 40000,
        sha256: "bbb",
        sections: { prose_chars: 20000, tool_disclosure_chars: 13000, skills_chars: 7000 },
      },
    ],
  };
  const cand = {
    variants: [
      {
        name: "router_sandbox",
        chars: 50000,
        sha256: "aaa",
        sections: { prose_chars: 25000, tool_disclosure_chars: 18000, skills_chars: 7000 },
      },
      {
        name: "worker_triage",
        chars: 32000,
        sha256: "ccc",
        sections: { prose_chars: 12000, tool_disclosure_chars: 13000, skills_chars: 7000 },
      },
    ],
  };

  const diff = compareDumps(base, cand);
  assert.equal(diff[0].identical, true);
  assert.equal(diff[0].deltaChars, 0);
  assert.equal(diff[1].identical, false);
  assert.equal(diff[1].deltaChars, -8000);
  assert.equal(diff[1].deltaPct, -20);
});

test("compareRuns flags hard-guardrail regressions and first tool divergence", () => {
  const baseRows = [
    {
      model: "deepseek-flash",
      case: "blocked_site_with_desktop",
      hard_guardrail: true,
      run: 1,
      pass: true,
      rounds: 3,
      help_calls: 0,
      tool_calls: ["web.read_pages", "device.list", "env.exec"],
      usage: { prompt_tokens: 12000, cached_tokens: 8000, completion_tokens: 200 },
      checks: [{ check: "required_tool:env.exec", pass: true }],
    },
  ];
  const candRows = [
    {
      model: "deepseek-flash",
      case: "blocked_site_with_desktop",
      hard_guardrail: true,
      run: 1,
      pass: false,
      rounds: 2,
      help_calls: 0,
      tool_calls: ["web.read_pages", "im_api.internal.send_message"],
      usage: { prompt_tokens: 10000, cached_tokens: 7000, completion_tokens: 150 },
      checks: [{ check: "required_tool:env.exec", pass: false }],
    },
  ];

  const runDiff = compareRuns(baseRows, candRows);
  assert.equal(runDiff.hardRegressions, 1);
  assert.equal(runDiff.summaries[0].divergence.index, 1);
  assert.equal(runDiff.summaries[0].divergence.base, "device.list");
  assert.equal(runDiff.summaries[0].divergence.cand, "im_api.internal.send_message");

  const md = renderMarkdown({ dumpDiff: [], runDiff });
  assert.match(md, /REGRESSION \(HARD\)/);
  assert.match(md, /step #2: base=`device\.list` vs cand=`im_api\.internal\.send_message`/);
});
