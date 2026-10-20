// Direct connections between an app's core and the machines it works with (stations), and the protocol on them:
// README.md says what is here and what is not.
export type {
  BiStream,
  CloseInfo,
  MeshConnection,
  MeshEndpoint,
  MeshVia,
  PeerAddr,
  RecvHalf,
  SendHalf,
  ViaChange,
} from "./link.ts";
export {
  CloseCode,
  MAX_FRAME_BYTES,
  MESH_ALPN,
  MeshError,
  StreamCode,
  type Body,
  type Headers,
} from "./wire.ts";
export {
  MeshClient,
  type MeshClientOptions,
  type MeshRequest,
  type MeshResponse,
} from "./client.ts";
export {
  serveMesh,
  serveMeshConnection,
  type Admission,
  type MeshReply,
  type MeshServer,
  type MeshServerOptions,
  type ServedRequest,
} from "./server.ts";
