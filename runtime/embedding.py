"""Numerical boundary only: FastEmbed inference and the existing NumPy kernels.

Selection, identity, windows, persistence, ranking, and protocol supervision are Lean.
"""
import json
import sys
import numpy as np
from fastembed import TextEmbedding

encoder = TextEmbedding(model_name=sys.argv[1], cache_dir=sys.argv[2], threads=int(sys.argv[3]))
if sys.argv[4:] == ["--preload"]:
    next(encoder.embed(["eggshell"], batch_size=1))
    raise SystemExit(0)
for line in sys.stdin:
    try:
        request = json.loads(line)
        if "texts" in request:
            vectors = []
            for vector in encoder.embed(request["texts"], batch_size=32):
                vector = np.asarray(vector, dtype=np.float32)
                norm = np.linalg.norm(vector)
                vectors.append((vector if norm == 0 else vector / norm).tolist())
            result = {"vectors": vectors}
        else:
            queries = [np.asarray(v, dtype=np.float32) for v in request["queries"]]
            result = {"scores": [max(float(np.dot(q, np.asarray(v, dtype=np.float32)))
                for q in queries for v in windows) for windows in request["candidates"]]}
        print(json.dumps(result, allow_nan=False, separators=(",", ":")), flush=True)
    except Exception as error:
        print(json.dumps({"error": str(error)}), flush=True)
