--!native
--!optimize 2
--!strict

local Types  = require(script.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type BulletProvider = Types.BulletProvider

local CosmeticBuilder = {}
CosmeticBuilder.__index = CosmeticBuilder

export type CosmeticBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, CosmeticBuilder))

-- BasePart cloned per fire call. Mutually exclusive with Provider — Provider wins.
function CosmeticBuilder.Template(self: CosmeticBuilder, Value: BasePart): CosmeticBuilder
    assert(
        typeof(Value) == "Instance" and Value:IsA("BasePart"),
        "CosmeticBuilder:Template — expected BasePart"
    )
    self._Config.CosmeticBulletTemplate = Value
    return self
end

-- Parent Instance for the cosmetic object. Defaults to workspace if nil.
function CosmeticBuilder.Container(self: CosmeticBuilder, Value: Instance): CosmeticBuilder
    assert(typeof(Value) == "Instance", "CosmeticBuilder:Container — expected Instance")
    self._Config.CosmeticBulletContainer = Value
    return self
end

-- Factory function called per fire call. Takes priority over Template.
-- Signature: (context: BulletContext) -> Instance?
function CosmeticBuilder.Provider(self: CosmeticBuilder, Callback: BulletProvider): CosmeticBuilder
    assert(type(Callback) == "function", "CosmeticBuilder:Provider — expected function")
    self._Config.CosmeticBulletProvider = Callback
    return self
end

-- When true (default), the cosmetic bullet Instance is destroyed automatically
-- when the cast terminates. Set to false to take ownership of cleanup yourself.
function CosmeticBuilder.AutoDelete(self: CosmeticBuilder, Value: boolean): CosmeticBuilder
    assert(type(Value) == "boolean", "CosmeticBuilder:AutoDelete — expected boolean")
    self._Config.AutoDeleteCosmeticBullet = Value
    return self
end

function CosmeticBuilder.Done(self: CosmeticBuilder): Types.BehaviorBuilder
    return self._Root
end

return CosmeticBuilder
