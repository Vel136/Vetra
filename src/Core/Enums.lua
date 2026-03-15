--!native
--!optimize 2
--!strict

--[[
    Vetra public enums.

    These are the named enum tables exposed on Vetra.Enums and used throughout
    Vetra's own internals. Having them in one module means:

      • There is one source of truth — no two tables defining the same names.
      • Internal modules (Drag physics, SimulateCast, etc.) and the public API
        (BehaviorBuilder, signal handlers) all reference the exact same values.
      • Adding a new enum value here automatically makes it available to every
        consumer without any sync step.

    Only enums that a user writing weapon code might need to reference belong
    here. Pure internal identifiers (PARALLEL_EVENT, VALIDATION_RESULT,
    VISUALIZER_HIT_TYPE) stay in Constants.
]]

-- ─── DragModel ───────────────────────────────────────────────────────────────
--[[
    Integer identifiers for each supported drag model.
    Stored as integers (not strings) so the physics hot path uses integer
    comparison rather than string comparison.

    Exposed publicly so users can write:
        :Drag():Model(Vetra.Enums.DragModel.G7):Done()
    and BehaviorBuilder re-exports this table as BehaviorBuilder.DragModel.
]]
local DragModel = table.freeze({
    Quadratic   = 1,   -- deceleration ∝ speed² (default; most accurate subsonic)
    Linear      = 2,   -- deceleration ∝ speed
    Exponential = 3,   -- deceleration ∝ eˢᵖᵉᵉᵈ (exotic high-drag shapes)
    -- G-series empirical Mach/Cd lookup tables
    G1          = 4,   -- flat-base spitzer; general-purpose standard
    G2          = 5,   -- Aberdeen J projectile; large-calibre / atypical shapes
    G3          = 6,   -- Finnish reference projectile; rarely used in practice
    G4          = 7,   -- seldom-used reference; included for completeness
    G5          = 8,   -- boat-tail spitzer; mid-range rifles
    G6          = 9,   -- semi-spitzer flat-base; shotgun slugs / blunt rounds
    G7          = 10,  -- long boat-tail; modern long-range / sniper standard
    G8          = 11,  -- flat-base semi-spitzer; hollow points / pistols
    GL          = 12,  -- lead round ball; cannons / muskets / buckshot
    -- User-supplied Mach/Cd table
    Custom      = 13,  -- requires CustomMachTable = { {mach, cd}, ... } on behavior
})

-- ─── TerminateReason ─────────────────────────────────────────────────────────
--[[
    Reason strings passed to OnPreTermination signal handlers.
    Users should compare against these rather than hardcoding raw strings so
    a rename here produces a detectable mismatch rather than a silent break.

        Signals.OnPreTermination:Connect(function(context, reason, mutate)
            if reason == Vetra.Enums.TerminateReason.Hit then
                mutate(true, nil)  -- cancel termination
            end
        end)
]]
local TerminateReason = table.freeze({
    Hit        = "hit",
    Distance   = "distance",
    Speed      = "speed",
    Manual     = "manual",
    CornerTrap = "corner_trap",
})

-- ─── Module Return ───────────────────────────────────────────────────────────

return table.freeze({
    DragModel     = DragModel,
    TerminateReason = TerminateReason,
})