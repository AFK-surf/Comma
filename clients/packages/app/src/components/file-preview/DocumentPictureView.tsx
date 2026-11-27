// A picture of a document's own: a file that goes with the document, which the document names by its file name
// (`documentPictureOf`). What shows the page reads the file (`DocumentPictureRead`); the page never loads an
// address written in the document's text. The page a reader edits draws it with what changes it
// (`DocumentEditor`); every other page of the document draws it as it is, here.
import { useEffect, useState } from "react";
import {
  documentPictureOf,
  documentVideoName,
  type DocumentPicture,
} from "./documentEditorModel";

/** Reads the file of this name, where the document has one. */
export type DocumentPictureRead = (name: string) => Promise<Blob | undefined>;

/**
 * The address a picture's file is drawn from, once it is read. Undefined: the file is being read. Null: the
 * document has no such file here.
 */
export function useDocumentPictureAddress(
  read: DocumentPictureRead | undefined,
  name: string
) {
  const [address, setAddress] = useState<string | null>();
  useEffect(() => {
    let current = true;
    let made: string | undefined;
    void (read ? read(name) : Promise.resolve(undefined)).then(
      (file) => {
        if (!current) return;
        if (file) made = URL.createObjectURL(file);
        setAddress(made ?? null);
      },
      () => {
        if (current) setAddress(null);
      }
    );
    return () => {
      current = false;
      if (made) URL.revokeObjectURL(made);
    };
  }, [read, name]);
  return address;
}

/** The picture as a page that is read shows it: at its side and its width, its words where it has no file here. */
export function DocumentPictureView({
  picture,
  read,
}: {
  picture: DocumentPicture;
  read: DocumentPictureRead;
}) {
  const address = useDocumentPictureAddress(read, picture.src);
  const words = picture.alt || picture.src;
  // Spans: the picture is drawn in the paragraph that holds it.
  return (
    <span
      className="comma-document-image"
      data-align={picture.align ?? "left"}
      data-testid="document-picture"
    >
      {address ? (
        <span
          className="comma-document-image-frame"
          // A drawing has no size of its own: it is as wide as the page.
          data-kind={/\.svg$/iu.test(picture.src) ? "drawing" : undefined}
          data-sized={picture.width === null ? undefined : "true"}
          style={{ width: picture.width ?? undefined }}
        >
          {documentVideoName(picture.src) ? (
            // oxlint-disable-next-line jsx-a11y/media-has-caption -- A file a person put in has no captions track.
            <video aria-label={words} controls preload="metadata" src={address} />
          ) : (
            <img alt={words} draggable={false} src={address} />
          )}
        </span>
      ) : address === undefined ? (
        // Its file is being read: a skeleton keeps a picture's place.
        <span
          aria-hidden="true"
          className="comma-document-image-skeleton"
          data-wait="true"
        />
      ) : (
        <span className="comma-document-image-wait">{words}</span>
      )}
    </span>
  );
}

/**
 * How a page draws a picture the document writes (`MarkdownStream`'s `renderPicture`): one of the document's own
 * from its file; for any other, undefined, and the page names it.
 */
export const documentPictureDrawer =
  (read: DocumentPictureRead) => (written: Parameters<typeof documentPictureOf>[0]) => {
    const picture = documentPictureOf(written);
    return picture ? <DocumentPictureView picture={picture} read={read} /> : undefined;
  };
