"""Convert MI-GAN .pt (state_dict) -> fp16 Core ML mlprogram. Usage: convert_migan.py <migan_inference.py> <weights.pt> <res> <out.mlpackage>"""
import sys, importlib.util, torch, numpy as np, coremltools as ct
src, wts, res, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
spec = importlib.util.spec_from_file_location("migan_inference", src)
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)  # file only imports torch/numpy
G = m.Generator(resolution=res).eval()
G.load_state_dict(torch.load(wts, map_location="cpu", weights_only=True))
x = torch.randn(1, 4, res, res)
with torch.no_grad():
    traced = torch.jit.trace(G, x)
ml = ct.convert(traced, convert_to="mlprogram", compute_precision=ct.precision.FLOAT16,
                minimum_deployment_target=ct.target.macOS14,
                inputs=[ct.TensorType(name="input", shape=(1, 4, res, res), dtype=np.float32)],
                outputs=[ct.TensorType(name="output", dtype=np.float32)])
ml.short_description = f"MI-GAN {res} Places2 inpainting. input=cat([mask-0.5, img*mask]) img in [-1,1], mask 1=known 0=hole; output RGB [-1,1]"
ml.save(out)
# parity check vs torch with a realistic input
img = torch.rand(1, 3, res, res) * 2 - 1
mask = torch.ones(1, 1, res, res); mask[..., res//4:res//2, res//4:3*res//4] = 0
xi = torch.cat([mask - 0.5, img * mask], 1)
with torch.no_grad(): ref = G(xi).numpy()
got = ml.predict({"input": xi.numpy()})["output"]
print(f"parity {out}: max|diff|={np.abs(ref-got).max():.4f} mean|diff|={np.abs(ref-got).mean():.5f} out range [{got.min():.2f},{got.max():.2f}]")
