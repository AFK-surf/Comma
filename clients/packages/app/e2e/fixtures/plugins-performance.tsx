import { useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { initializeCommaI18n } from "@comma/i18n";
import { PluginCatalog, type PluginSkillDefinition } from "@comma/ui";
import "../../src/styles.css";

initializeCommaI18n(["en"]);
const count = Number(new URLSearchParams(location.search).get("count") ?? 50);
const skills: PluginSkillDefinition[] = Array.from({ length: count }, (_, index) => ({
  id: `skill-${index}`,
  name: `Skill ${index}`,
  description: `Use this workspace skill to review project ${index} and prepare an implementation plan.`,
  categoryId: index % 2 ? "custom" : "system",
}));
const categories = [
  { id: "custom", name: "Custom" },
  { id: "system", name: "System" },
];
const mountStarted = performance.now();
declare global {
  interface Window {
    pluginsMount: { elapsedMs: number; domNodes: number; rows: number } | undefined;
  }
}

function Fixture() {
  const [selected, setSelected] = useState("");
  useLayoutEffect(() => {
    requestAnimationFrame(() =>
      requestAnimationFrame(() => {
        window.pluginsMount = {
          elapsedMs: performance.now() - mountStarted,
          domNodes: document.querySelectorAll("*").length,
          rows: document.querySelectorAll('[data-slot="plugin-list-item"]').length,
        };
      })
    );
  }, []);
  return (
    <div style={{ height: "100vh" }}>
      <output data-testid="opened-skill" hidden>
        {selected}
      </output>
      <PluginCatalog
        categories={[]}
        defaultTab="skills"
        skills={skills}
        skillCategories={categories}
        onSkillOpen={(skill, trigger) => setSelected(`${skill.id}:${trigger}`)}
      />
    </div>
  );
}

createRoot(document.getElementById("root")!).render(<Fixture />);
