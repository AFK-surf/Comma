# One render job, run by Comma in a background Blender on a snapshot of the
# scene: `blender -b <snapshot.blend> --python render_job.py -- <job.json>`.
# The job file names the output and optional overrides; the result goes to
# `<output>.result.json`. The interactive Blender stays free while it runs.

import json
import sys
import time
import traceback

import bpy


def main():
    job_file = sys.argv[sys.argv.index("--") + 1]
    with open(job_file, "r", encoding="utf-8") as f:
        job = json.load(f)
    output = job["output"]
    result = {"output": output}
    started = time.time()
    try:
        scene = bpy.context.scene
        if job.get("camera"):
            camera = bpy.data.objects.get(job["camera"])
            if camera is None or camera.type != "CAMERA":
                raise ValueError("no camera named %s" % job["camera"])
            scene.camera = camera
        if scene.camera is None:
            raise ValueError("the scene has no camera")
        if job.get("frame") is not None:
            scene.frame_set(int(job["frame"]))
        if job.get("resolution_percentage"):
            scene.render.resolution_percentage = int(job["resolution_percentage"])
        if job.get("samples") and scene.render.engine == "CYCLES":
            scene.cycles.samples = int(job["samples"])
        scene.render.image_settings.file_format = "PNG"
        scene.render.filepath = output
        bpy.ops.render.render(write_still=True)
        result.update(
            {
                "state": "done",
                "engine": scene.render.engine,
                "resolution": [
                    scene.render.resolution_x * scene.render.resolution_percentage // 100,
                    scene.render.resolution_y * scene.render.resolution_percentage // 100,
                ],
                "frame": scene.frame_current,
            }
        )
    except Exception:  # noqa: BLE001 - the job's failure is its result
        result.update({"state": "failed", "error": traceback.format_exc(limit=6)})
    result["seconds"] = round(time.time() - started, 1)
    with open(output + ".result.json", "w", encoding="utf-8") as f:
        json.dump(result, f)


main()
