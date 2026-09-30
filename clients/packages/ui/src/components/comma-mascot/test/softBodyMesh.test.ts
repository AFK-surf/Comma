import { describe, expect, it } from "vitest";
import {
  beginSoftBodyDrag,
  createSoftBodyMesh,
  endSoftBodyDrag,
  getSoftBodyNode,
  moveSoftBodyDrag,
  softBodyMaxDragDistance,
  stepSoftBodyMesh,
  warpPoint,
} from "../softBodyMesh";

describe("Comma mascot soft-body mesh", () => {
  it("clamps exaggerated pulls and keeps every mesh cell from folding", () => {
    expect(softBodyMaxDragDistance).toBe(30);

    const mesh = createSoftBodyMesh();
    const source = { x: 104, y: 104 };
    const farEdge = { x: 248, y: 248 };
    const before = warpPoint(mesh, source);
    const farEdgeBefore = warpPoint(mesh, farEdge);

    beginSoftBodyDrag(mesh, source);
    moveSoftBodyDrag(mesh, { x: -1_000, y: -1_000 });
    for (let frame = 0; frame < 8; frame += 1) {
      stepSoftBodyMesh(mesh, 1 / 60);
    }
    const after = warpPoint(mesh, source);
    const farEdgeAfter = warpPoint(mesh, farEdge);
    const displacement = Math.hypot(after.x - before.x, after.y - before.y);

    expect(displacement).toBeCloseTo(softBodyMaxDragDistance, 5);
    expect(farEdgeAfter).toEqual(farEdgeBefore);
    for (let row = 0; row < mesh.rows - 1; row += 1) {
      for (let column = 0; column < mesh.columns - 1; column += 1) {
        const topLeft = getSoftBodyNode(mesh, row * mesh.columns + column)!.position;
        const topRight = getSoftBodyNode(
          mesh,
          row * mesh.columns + column + 1
        )!.position;
        const bottomLeft = getSoftBodyNode(
          mesh,
          (row + 1) * mesh.columns + column
        )!.position;
        const signedArea =
          (topRight.x - topLeft.x) * (bottomLeft.y - topLeft.y) -
          (topRight.y - topLeft.y) * (bottomLeft.x - topLeft.x);
        expect(signedArea).toBeGreaterThan(0);
      }
    }
  });

  it("carries release velocity, overshoots, and settles back at rest", () => {
    const mesh = createSoftBodyMesh();
    beginSoftBodyDrag(mesh, { x: 104, y: 104 });
    moveSoftBodyDrag(mesh, { x: 156, y: 104 });
    for (let frame = 0; frame < 5; frame += 1) {
      stepSoftBodyMesh(mesh, 1 / 60);
    }
    const draggedIndex = mesh.drag!.index;
    const restX = getSoftBodyNode(mesh, draggedIndex)!.rest.x;
    endSoftBodyDrag(mesh);

    let crossedRest = false;
    let furthestOvershoot = 0;
    let frame = 0;
    while (stepSoftBodyMesh(mesh, 1 / 60) && frame < 600) {
      const overshoot = restX - getSoftBodyNode(mesh, draggedIndex)!.position.x;
      furthestOvershoot = Math.max(furthestOvershoot, overshoot);
      if (overshoot > 0) {
        crossedRest = true;
      }
      frame += 1;
    }

    expect(crossedRest).toBe(true);
    expect(furthestOvershoot).toBeGreaterThan(1);
    expect(frame).toBeLessThan(600);
    for (const node of mesh.nodes) {
      expect(node.position).toEqual(node.rest);
      expect(node.previous).toEqual(node.rest);
    }
  });
});
