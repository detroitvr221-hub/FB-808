import coremltools as ct
import coremltools.optimize.coreml as cto
m = ct.models.MLModel("StemSeparator.mlpackage")
cfg = cto.OptimizationConfig(global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", weight_threshold=4096))
q = cto.linear_quantize_weights(m, config=cfg)
q.save("StemSeparator_int8.mlpackage")
print("saved int8")
