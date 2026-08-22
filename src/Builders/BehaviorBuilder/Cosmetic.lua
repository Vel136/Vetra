--!native
--!optimize 2
--!strict

local Types  = require(script.Parent.Parent.Parent.Types)

type BuiltBehavior = Types.BuiltBehavior
type BulletProvider = Types.BulletProvider

local CosmeticBuilder = {}
CosmeticBuilder.__index = CosmeticBuilder

export type CosmeticBuilder = typeof(setmetatable({} :: {
    _Root   : Types.BehaviorBuilder,
    _Config : BuiltBehavior,
}, CosmeticBuilder))

function CosmeticBuilder.Template(self: CosmeticBuilder, Value: BasePart): CosmeticBuilder
    assert(
        typeof(Value) == "Instance" and Value:IsA("BasePart"),
        "CosmeticBuilder:Template — expected BasePart"
    )
    self._Config.CosmeticBulletTemplate = Value
    self._Dirty.CosmeticBulletTemplate  = true
    return self
end

function CosmeticBuilder.Container(self: CosmeticBuilder, Value: Instance): CosmeticBuilder
    assert(typeof(Value) == "Instance", "CosmeticBuilder:Container — expected Instance")
    self._Config.CosmeticBulletContainer = Value
    self._Dirty.CosmeticBulletContainer  = true
    return self
end

function CosmeticBuilder.Provider(self: CosmeticBuilder, Callback: BulletProvider): CosmeticBuilder
    assert(type(Callback) == "function", "CosmeticBuilder:Provider — expected function")
    self._Config.CosmeticBulletProvider = Callback
    self._Dirty.CosmeticBulletProvider  = true
    return self
end

function CosmeticBuilder.AutoDelete(self: CosmeticBuilder, Value: boolean): CosmeticBuilder
    assert(type(Value) == "boolean", "CosmeticBuilder:AutoDelete — expected boolean")
    self._Config.AutoDeleteCosmeticBullet = Value
    self._Dirty.AutoDeleteCosmeticBullet  = true
    return self
end

function CosmeticBuilder.NonQueryable(self: CosmeticBuilder, Value: boolean): CosmeticBuilder
    assert(type(Value) == "boolean", "CosmeticBuilder:NonQueryable — expected boolean")
    self._Config.CosmeticBulletNonQueryable = Value
    self._Dirty.CosmeticBulletNonQueryable  = true
    return self
end

function CosmeticBuilder.Done(self: CosmeticBuilder): Types.BehaviorBuilder
    return self._Root
end

return CosmeticBuilder
