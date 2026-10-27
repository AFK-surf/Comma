import { NotebookPen, Plus, Settings, Trash2 } from "lucide-react";
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useState,
  type ReactNode,
} from "react";
import { List, ListItem, ListSection } from "@/components/list";
import { AppShell } from "@/components/navigation";
import { Screen } from "@/components/screen";
import { Sheet } from "@/components/sheet";
import { SplitView } from "@/components/split-view";
import { EmptyState, ErrorState, LoadingList } from "@/components/state";
import { useToast } from "@/components/toast";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Textarea } from "@/components/ui/textarea";
import { comma, CommaError } from "./comma/sdk";

/**
 * The example app, built as DESIGN.md asks: two sections in a tab bar (phone)
 * or a sidebar (iPad, web); Notes is a list and its detail, pushed on a phone
 * and side by side on wider screens; a new note is written in a sheet.
 */
export function App() {
  return (
    <NotesProvider>
      <AppShell
        destinations={[
          {
            id: "notes",
            title: "Notes",
            icon: <NotebookPen />,
            root: <NotesSection />,
          },
          {
            id: "settings",
            title: "Settings",
            icon: <Settings />,
            root: <SettingsScreen />,
          },
        ]}
      />
    </NotesProvider>
  );
}

interface Note {
  id: string;
  text: string;
  /** When it was written. Notes kept by an earlier version of this app have none. */
  at?: number;
}

// The viewer's notes, on all their devices: one value in the `user` store.
const notesKey = "notes";

interface Notes {
  notes: Note[] | null;
  error: string | null;
  viewer: string | null;
  reload(): void;
  add(text: string): Promise<boolean>;
  remove(id: string): Promise<boolean>;
}

const NotesContext = createContext<Notes | null>(null);

function useNotes(): Notes {
  const notes = useContext(NotesContext);
  if (!notes) throw new Error("useNotes needs a <NotesProvider> above it.");
  return notes;
}

/** The notes, read once and shared by every screen, so a change shows everywhere at once. */
function NotesProvider({ children }: { children: ReactNode }) {
  const [notes, setNotes] = useState<Note[] | null>(null);
  const [version, setVersion] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [viewer, setViewer] = useState<string | null>(null);

  const report = useCallback((reason: unknown) => {
    setError(
      reason instanceof CommaError
        ? `${reason.code}: ${reason.message}`
        : String(reason),
    );
  }, []);

  const reload = useCallback(() => {
    setError(null);
    void comma.storage.user.get<Note[]>(notesKey).then((stored) => {
      setNotes(stored?.value ?? []);
      setVersion(stored?.version ?? 0);
    }, report);
  }, [report]);

  useEffect(() => {
    reload();
    if (comma.supports("viewer"))
      void comma.viewer().then((found) => setViewer(found.name), report);
  }, [reload, report]);

  // `ifVersion` refuses a write when another device changed the notes first.
  const save = useCallback(
    async (next: Note[]) => {
      try {
        const saved = await comma.storage.user.put(notesKey, next, {
          ifVersion: version,
        });
        setNotes(next);
        setVersion(saved.version);
        setError(null);
        return true;
      } catch (reason) {
        report(reason);
        return false;
      }
    },
    [version, report],
  );

  const value = useMemo<Notes>(
    () => ({
      notes,
      error,
      viewer,
      reload,
      add: (text) =>
        save([
          { id: `${Date.now().toString(36)}-${notes?.length ?? 0}`, text, at: Date.now() },
          ...(notes ?? []),
        ]),
      remove: (id) => save((notes ?? []).filter((note) => note.id !== id)),
    }),
    [notes, error, viewer, reload, save],
  );
  return <NotesContext.Provider value={value}>{children}</NotesContext.Provider>;
}

/** A note's first line is its title, as in Notes. */
function titleOf(note: Note | undefined): string {
  return note?.text.split("\n")[0]?.trim() || "Note";
}

function dateOf(note: Note): string {
  if (typeof note.at !== "number" || !Number.isFinite(note.at)) return "";
  return new Date(note.at).toLocaleDateString(undefined, {
    month: "short",
    day: "numeric",
  });
}

function NotesSection() {
  const { notes } = useNotes();
  return (
    <SplitView
      list={(open, selected) => <NotesScreen onOpen={open} selected={selected} />}
      detail={(id, close) => ({
        title: titleOf(notes?.find((note) => note.id === id)),
        screen: <NoteScreen id={id} onClose={close} />,
      })}
      placeholder={
        <EmptyState
          className="border-0"
          icon={<NotebookPen />}
          title="No note open"
          description="Choose a note to read it here."
        />
      }
    />
  );
}

function NotesScreen({
  onOpen,
  selected,
}: {
  onOpen: (id: string) => void;
  selected: string | null;
}) {
  const { notes, error, reload, add } = useNotes();
  const toast = useToast();
  const [composing, setComposing] = useState(false);
  const [draft, setDraft] = useState("");

  async function save() {
    const text = draft.trim();
    if (!text) return;
    if (await add(text)) {
      setComposing(false);
      setDraft("");
      toast("Note added", { tone: "success" });
    }
  }

  return (
    <Screen
      title="Notes"
      actions={
        <Button
          type="button"
          variant="ghost"
          size="icon"
          aria-label="New note"
          className="text-primary hover:text-primary/80"
          disabled={notes === null}
          onClick={() => setComposing(true)}
        >
          <Plus className="size-5" />
        </Button>
      }
    >
      {error ? <ErrorState detail={error} onRetry={reload} /> : null}
      {notes === null ? (
        <LoadingList />
      ) : notes.length === 0 ? (
        <EmptyState
          icon={<NotebookPen />}
          title="No notes yet"
          description="Notes stay with you on every device."
          action={
            <Button type="button" onClick={() => setComposing(true)}>
              New note
            </Button>
          }
        />
      ) : (
        <List aria-label="Notes">
          {notes.map((note) => (
            <ListItem
              key={note.id}
              title={titleOf(note)}
              description={[dateOf(note), note.text.split("\n").slice(1).join(" ").trim()]
                .filter(Boolean)
                .join("  ")}
              selected={note.id === selected}
              onClick={() => onOpen(note.id)}
            />
          ))}
        </List>
      )}
      <Sheet
        open={composing}
        onClose={() => setComposing(false)}
        title="New note"
        confirm={{
          label: "Add",
          onConfirm: () => void save(),
          disabled: !draft.trim(),
        }}
      >
        <div className="flex flex-col gap-2">
          <Label htmlFor="note-text">Note</Label>
          <Textarea
            id="note-text"
            autoFocus
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="The first line is the title"
          />
        </div>
      </Sheet>
    </Screen>
  );
}

function NoteScreen({ id, onClose }: { id: string; onClose: () => void }) {
  const { notes, remove } = useNotes();
  const toast = useToast();
  const [confirming, setConfirming] = useState(false);
  const note = notes?.find((found) => found.id === id);

  async function del() {
    setConfirming(false);
    if (await remove(id)) {
      toast("Note deleted");
      onClose();
    }
  }

  return (
    <Screen
      title={titleOf(note)}
      actions={
        <Button
          type="button"
          variant="ghost"
          size="icon"
          aria-label="Delete note"
          className="text-primary hover:text-primary/80"
          disabled={!note}
          onClick={() => setConfirming(true)}
        >
          <Trash2 className="size-5" />
        </Button>
      }
    >
      {note ? (
        <article className="flex flex-col gap-1 pt-2">
          {dateOf(note) ? (
            <p className="text-footnote text-muted-foreground">
              <time dateTime={new Date(note.at!).toISOString()}>{dateOf(note)}</time>
            </p>
          ) : null}
          <h2 className="text-title-2">{titleOf(note)}</h2>
          <p className="text-body whitespace-pre-wrap">
            {note.text.split("\n").slice(1).join("\n").trim()}
          </p>
        </article>
      ) : null}
      <Sheet
        open={confirming}
        onClose={() => setConfirming(false)}
        title="Delete note?"
        confirm={{ label: "Delete", onConfirm: () => void del(), destructive: true }}
      >
        <p className="text-subheadline text-muted-foreground">
          The note is deleted on every device. This cannot be undone.
        </p>
      </Sheet>
    </Screen>
  );
}

function SettingsScreen() {
  const { notes, viewer } = useNotes();
  return (
    <Screen title="Settings">
      <ListSection header="Account">
        <List>
          <ListItem title="Name" trailing={viewer ?? "Guest"} />
        </List>
      </ListSection>
      <ListSection
        header="About"
        footer="Your notes are in your own store, synced across your devices."
      >
        <List>
          <ListItem title="Version" trailing={String(comma.app.version)} />
          <ListItem title="Notes" trailing={String(notes?.length ?? 0)} />
        </List>
      </ListSection>
    </Screen>
  );
}
