--!strict
--!optimize 2
--!native

local FrameBudget = {}

local Vetra = script.Parent.Parent
local Core  = Vetra.Core

local Constants = require(Core.Constants)

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

return table.freeze(FrameBudget)
