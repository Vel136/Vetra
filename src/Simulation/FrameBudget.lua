--!native
--!optimize 2
--!strict

-- ─── FrameBudget ─────────────────────────────────────────────────────────────
--[[
    Per-frame CPU budget tracking for high-fidelity resimulation.
]]

local Identity    = "FrameBudget"
local FrameBudget = {}
FrameBudget.__type = Identity

-- ─── References ──────────────────────────────────────────────────────────────

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

-- ─── Module References ───────────────────────────────────────────────────────

local LogService = require(Core.Logger)
local Constants  = require(Core.Constants)

-- ─── Logger ──────────────────────────────────────────────────────────────────

local Logger = LogService.new(Identity, false)

-- ─── Module ──────────────────────────────────────────────────────────────────

function FrameBudget.new(BudgetMs: number?): { RemainingMicroseconds: number, BudgetMs: number }
	local ResolvedBudgetMs = BudgetMs or Constants.GLOBAL_FRAME_BUDGET_MS
	return {
		RemainingMicroseconds = ResolvedBudgetMs * 1000,
		BudgetMs              = ResolvedBudgetMs,
	}
end

function FrameBudget.Reset(Budget: any)
	Budget.RemainingMicroseconds = Budget.BudgetMs * 1000
end

function FrameBudget.Consume(Budget: any, ElapsedSeconds: number)
	Budget.RemainingMicroseconds -= ElapsedSeconds * 1e6
end

function FrameBudget.IsExhausted(Budget: any): boolean
	return Budget.RemainingMicroseconds <= 0
end

-- ─── Module Return ───────────────────────────────────────────────────────────

local FrameBudgetMetatable = table.freeze({
	__index = function(_, Key)
		Logger:Warn(string.format("FrameBudget: nil key '%s'", tostring(Key)))
	end,
	__newindex = function(_, Key, Value)
		Logger:Error(string.format(
			"FrameBudget: write to protected key '%s' = '%s'",
			tostring(Key),
			tostring(Value)
			))
	end,
})

return setmetatable(FrameBudget, FrameBudgetMetatable)