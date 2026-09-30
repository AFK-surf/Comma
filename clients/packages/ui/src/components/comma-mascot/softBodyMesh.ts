import { motionMascotElastic } from "../../tokens/motion";

export type Point = { x: number; y: number };

type MeshNode = {
  position: Point;
  previous: Point;
  rest: Point;
};

type MeshConstraint = {
  a: number;
  b: number;
  restLength: number;
  stiffness: number;
};

type MeshDrag = {
  anchorIndices: number[];
  index: number;
  origin: Point;
  previousTarget: Point;
  target: Point;
};

export type SoftBodyMesh = {
  columns: number;
  constraints: MeshConstraint[];
  drag: MeshDrag | null;
  max: Point;
  min: Point;
  nodes: MeshNode[];
  rows: number;
};

const STRUCTURAL_STIFFNESS = 0.68;
const SHEAR_STIFFNESS = 0.48;
const BEND_STIFFNESS = 0.24;
const CONSTRAINT_ITERATIONS = 5;
const FIXED_STEP_SECONDS = 1 / 120;
const MAX_FRAME_SECONDS = 1 / 30;
const REST_DISTANCE = 0.025;
const REST_SPEED = 0.12;

/** A guarded medium pull: visibly elastic while the anchored mesh remains non-folding. */
export const softBodyMaxDragDistance = 30;

const distance = (a: Point, b: Point) => Math.hypot(b.x - a.x, b.y - a.y);

const clonePoint = ({ x, y }: Point): Point => ({ x, y });

const nodeIndex = (mesh: Pick<SoftBodyMesh, "columns">, column: number, row: number) =>
  row * mesh.columns + column;

const addConstraint = (mesh: SoftBodyMesh, a: number, b: number, stiffness: number) => {
  mesh.constraints.push({
    a,
    b,
    restLength: distance(mesh.nodes[a]!.rest, mesh.nodes[b]!.rest),
    stiffness,
  });
};

export const createSoftBodyMesh = ({
  columns = 6,
  rows = 6,
  min = { x: 8, y: 8 },
  max = { x: 248, y: 248 },
}: {
  columns?: number;
  rows?: number;
  min?: Point;
  max?: Point;
} = {}): SoftBodyMesh => {
  const mesh: SoftBodyMesh = {
    columns,
    constraints: [],
    drag: null,
    max,
    min,
    nodes: [],
    rows,
  };

  for (let row = 0; row < rows; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      const point = {
        x: min.x + ((max.x - min.x) * column) / (columns - 1),
        y: min.y + ((max.y - min.y) * row) / (rows - 1),
      };
      mesh.nodes.push({
        position: clonePoint(point),
        previous: clonePoint(point),
        rest: point,
      });
    }
  }

  for (let row = 0; row < rows; row += 1) {
    for (let column = 0; column < columns; column += 1) {
      const current = nodeIndex(mesh, column, row);
      if (column + 1 < columns) {
        addConstraint(
          mesh,
          current,
          nodeIndex(mesh, column + 1, row),
          STRUCTURAL_STIFFNESS
        );
      }
      if (row + 1 < rows) {
        addConstraint(
          mesh,
          current,
          nodeIndex(mesh, column, row + 1),
          STRUCTURAL_STIFFNESS
        );
      }
      if (column + 1 < columns && row + 1 < rows) {
        addConstraint(
          mesh,
          current,
          nodeIndex(mesh, column + 1, row + 1),
          SHEAR_STIFFNESS
        );
        addConstraint(
          mesh,
          nodeIndex(mesh, column + 1, row),
          nodeIndex(mesh, column, row + 1),
          SHEAR_STIFFNESS
        );
      }
      if (column + 2 < columns) {
        addConstraint(mesh, current, nodeIndex(mesh, column + 2, row), BEND_STIFFNESS);
      }
      if (row + 2 < rows) {
        addConstraint(mesh, current, nodeIndex(mesh, column, row + 2), BEND_STIFFNESS);
      }
    }
  }

  return mesh;
};

const isPinnedDuringDrag = (mesh: SoftBodyMesh, index: number) =>
  mesh.drag?.index === index || mesh.drag?.anchorIndices.includes(index) === true;

const pinDraggedNodes = (mesh: SoftBodyMesh) => {
  if (!mesh.drag) {
    return;
  }
  const draggedNode = mesh.nodes[mesh.drag.index]!;
  draggedNode.previous = clonePoint(mesh.drag.previousTarget);
  draggedNode.position = clonePoint(mesh.drag.target);
  for (const anchorIndex of mesh.drag.anchorIndices) {
    const anchor = mesh.nodes[anchorIndex]!;
    anchor.position = clonePoint(anchor.rest);
    anchor.previous = clonePoint(anchor.rest);
  }
};

const solveConstraint = (mesh: SoftBodyMesh, constraint: MeshConstraint) => {
  const a = mesh.nodes[constraint.a]!;
  const b = mesh.nodes[constraint.b]!;
  const dx = b.position.x - a.position.x;
  const dy = b.position.y - a.position.y;
  const currentLength = Math.hypot(dx, dy) || 1;
  const correction =
    ((currentLength - constraint.restLength) / currentLength) *
    constraint.stiffness *
    0.5;
  const offsetX = dx * correction;
  const offsetY = dy * correction;

  if (!isPinnedDuringDrag(mesh, constraint.a)) {
    a.position.x += offsetX;
    a.position.y += offsetY;
  }
  if (!isPinnedDuringDrag(mesh, constraint.b)) {
    b.position.x -= offsetX;
    b.position.y -= offsetY;
  }
};

const integrateStep = (mesh: SoftBodyMesh, dtSeconds: number) => {
  const { damping, mass, stiffness } = motionMascotElastic;
  const velocityRetention = Math.exp(-damping * dtSeconds);

  for (let index = 0; index < mesh.nodes.length; index += 1) {
    if (isPinnedDuringDrag(mesh, index)) {
      continue;
    }
    const node = mesh.nodes[index]!;
    const velocityX = (node.position.x - node.previous.x) * velocityRetention;
    const velocityY = (node.position.y - node.previous.y) * velocityRetention;
    const accelerationX = ((node.rest.x - node.position.x) * stiffness) / mass;
    const accelerationY = ((node.rest.y - node.position.y) * stiffness) / mass;
    const current = clonePoint(node.position);

    node.position.x += velocityX + accelerationX * dtSeconds * dtSeconds;
    node.position.y += velocityY + accelerationY * dtSeconds * dtSeconds;
    node.previous = current;
  }

  pinDraggedNodes(mesh);
  for (let iteration = 0; iteration < CONSTRAINT_ITERATIONS; iteration += 1) {
    for (const constraint of mesh.constraints) {
      solveConstraint(mesh, constraint);
    }
    pinDraggedNodes(mesh);
  }

  if (mesh.drag) {
    mesh.drag.previousTarget = clonePoint(mesh.drag.target);
  }
};

export const stepSoftBodyMesh = (mesh: SoftBodyMesh, frameSeconds: number) => {
  let remaining = Math.min(Math.max(frameSeconds, 0), MAX_FRAME_SECONDS);
  while (remaining > Number.EPSILON) {
    const dtSeconds = Math.min(FIXED_STEP_SECONDS, remaining);
    integrateStep(mesh, dtSeconds);
    remaining -= dtSeconds;
  }
  const moving = isSoftBodyMoving(mesh);
  if (!moving && !mesh.drag) {
    resetSoftBodyMesh(mesh);
  }
  return moving;
};

export const isSoftBodyMoving = (mesh: SoftBodyMesh) => {
  if (mesh.drag) {
    return true;
  }
  return mesh.nodes.some((node) => {
    const displacement = distance(node.position, node.rest);
    const speed = distance(node.position, node.previous) / FIXED_STEP_SECONDS;
    return displacement > REST_DISTANCE || speed > REST_SPEED;
  });
};

export const beginSoftBodyDrag = (mesh: SoftBodyMesh, point: Point) => {
  let nearestIndex = 0;
  let nearestDistance = Number.POSITIVE_INFINITY;
  mesh.nodes.forEach((node, index) => {
    const candidateDistance = distance(node.position, point);
    if (candidateDistance < nearestDistance) {
      nearestDistance = candidateDistance;
      nearestIndex = index;
    }
  });
  const draggedPosition = mesh.nodes[nearestIndex]!.position;
  mesh.drag = {
    anchorIndices: mesh.nodes
      .map((node, index) => ({ index, distance: distance(node.rest, point) }))
      .filter(({ index }) => index !== nearestIndex)
      .toSorted((a, b) => b.distance - a.distance)
      .slice(0, 3)
      .map(({ index }) => index),
    index: nearestIndex,
    origin: clonePoint(point),
    previousTarget: clonePoint(draggedPosition),
    target: clonePoint(draggedPosition),
  };
};

export const moveSoftBodyDrag = (mesh: SoftBodyMesh, point: Point) => {
  if (!mesh.drag) {
    return;
  }
  const deltaX = point.x - mesh.drag.origin.x;
  const deltaY = point.y - mesh.drag.origin.y;
  const length = Math.hypot(deltaX, deltaY) || 1;
  const scale = Math.min(1, softBodyMaxDragDistance / length);
  const rest = mesh.nodes[mesh.drag.index]!.rest;
  mesh.drag.target = {
    x: rest.x + deltaX * scale,
    y: rest.y + deltaY * scale,
  };
};

export const endSoftBodyDrag = (mesh: SoftBodyMesh) => {
  mesh.drag = null;
};

export const resetSoftBodyMesh = (mesh: SoftBodyMesh) => {
  mesh.drag = null;
  for (const node of mesh.nodes) {
    node.position = clonePoint(node.rest);
    node.previous = clonePoint(node.rest);
  }
};

export const warpPoint = (mesh: SoftBodyMesh, point: Point): Point => {
  const normalizedX =
    ((point.x - mesh.min.x) / (mesh.max.x - mesh.min.x)) * (mesh.columns - 1);
  const normalizedY =
    ((point.y - mesh.min.y) / (mesh.max.y - mesh.min.y)) * (mesh.rows - 1);
  const column = Math.min(Math.max(Math.floor(normalizedX), 0), mesh.columns - 2);
  const row = Math.min(Math.max(Math.floor(normalizedY), 0), mesh.rows - 2);
  const tx = Math.min(Math.max(normalizedX - column, 0), 1);
  const ty = Math.min(Math.max(normalizedY - row, 0), 1);
  const topLeft = mesh.nodes[nodeIndex(mesh, column, row)]!.position;
  const topRight = mesh.nodes[nodeIndex(mesh, column + 1, row)]!.position;
  const bottomLeft = mesh.nodes[nodeIndex(mesh, column, row + 1)]!.position;
  const bottomRight = mesh.nodes[nodeIndex(mesh, column + 1, row + 1)]!.position;

  return {
    x:
      topLeft.x * (1 - tx) * (1 - ty) +
      topRight.x * tx * (1 - ty) +
      bottomLeft.x * (1 - tx) * ty +
      bottomRight.x * tx * ty,
    y:
      topLeft.y * (1 - tx) * (1 - ty) +
      topRight.y * tx * (1 - ty) +
      bottomLeft.y * (1 - tx) * ty +
      bottomRight.y * tx * ty,
  };
};

export const getSoftBodyNode = (mesh: SoftBodyMesh, index: number) => mesh.nodes[index];
