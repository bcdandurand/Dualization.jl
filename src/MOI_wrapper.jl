# Supported Functions
const SF = Union{MOI.SingleVariable, 
                 MOI.ScalarAffineFunction{Float64}, 
                 MOI.VectorOfVariables, 
                 MOI.VectorAffineFunction{Float64}}

# Supported Sets
const SS = Union{MOI.EqualTo{Float64}, MOI.GreaterThan{Float64}, MOI.LessThan{Float64}, 
                 MOI.Zeros, MOI.Nonnegatives, MOI.Nonpositives, 
                 MOI.SecondOrderCone, MOI.RotatedSecondOrderCone,
                 MOI.ExponentialCone, MOI.DualExponentialCone,
                 MOI.PowerCone, MOI.DualPowerCone,
                 MOI.PositiveSemidefiniteConeTriangle}

mutable struct DualOptimizer{OT <: MOI.ModelLike} <: MOI.AbstractOptimizer
    dual_problem::DualProblem

    function DualOptimizer{OT}(dual_problem::DualProblem) where {OT <: MOI.ModelLike}
        return new(dual_problem)
    end
    function DualOptimizer(dual_optimizer::OT) where {OT <: MOI.ModelLike}
        return DualOptimizer{OT}(DualProblem(dual_optimizer))
    end
end

function MOI.supports(::DualOptimizer,
                      ::Union{MOI.ObjectiveSense,
                              MOI.ObjectiveFunction{MOI.SingleVariable},
                              MOI.ObjectiveFunction{MOI.ScalarAffineFunction{Float64}}})
    return true
end

function MOI.supports_constraint(optimizer::DualOptimizer, F::Type{<:SF}, S::Type{<:SS})
    return MOI.supports_constraint(optimizer.dual_problem.dual_model, F, S)
end

function MOI.supports_constraint(::DualOptimizer, ::Type{MOI.AbstractFunction}, ::Type{MOI.AbstractSet})
    return false 
end

function MOI.copy_to(dest::DualOptimizer, src::MOI.ModelLike; kwargs...)
    # Dualize the original problem
    dualize(src, dest.dual_problem)

    # Identity IndexMap
    idx_map = MOIU.IndexMap()

    for vi in MOI.get(src, MOI.ListOfVariableIndices())
        setindex!(idx_map, vi, vi)
    end

    for (F, S) in MOI.get(src, MOI.ListOfConstraints())
        for con in MOI.get(src, MOI.ListOfConstraintIndices{F,S}())
            setindex!(idx_map, con, con)
        end
    end
    return idx_map
end

function MOI.optimize!(optimizer::DualOptimizer)
    return MOI.optimize!(optimizer.dual_problem.dual_model)    
end

function MOI.is_empty(optimizer::DualOptimizer)
    return (MOI.is_empty(optimizer.dual_problem.dual_model)) && is_empty(optimizer.dual_problem.primal_dual_map)
end

function MOI.empty!(optimizer::DualOptimizer)
    MOI.empty!(optimizer.dual_problem.dual_model)
    empty!(optimizer.dual_problem.primal_dual_map)
    return
end

# MOI.get auxiliary functions
function get_ci_dual_problem(optimizer::DualOptimizer, vi::VI)
    return optimizer.dual_problem.primal_dual_map.primal_var_dual_con[vi]
end

function get_ci_dual_problem(optimizer::DualOptimizer, ci::CI)
    return optimizer.dual_problem.primal_dual_map.primal_con_dual_con[ci]
end

function get_ci_dual_optimizer(optimizer::DualOptimizer, vi::VI)
    return get_ci_dual_problem(optimizer, vi)
end

function get_ci_dual_optimizer(optimizer::DualOptimizer, ci::CI)
    return ci
end

function get_primal_ci_constant(optimizer::DualOptimizer, ci::CI)
    return first(get_primal_ci_constants(optimizer, ci))
end

function get_primal_ci_constants(optimizer::DualOptimizer, ci::CI)
    return optimizer.dual_problem.primal_dual_map.primal_con_constants[ci]
end

function get_vi_dual_problem(optimizer::DualOptimizer, ci::CI)
    return first(get_vis_dual_problem(optimizer, ci))
end

function get_vis_dual_problem(optimizer::DualOptimizer, ci::CI)
    return optimizer.dual_problem.primal_dual_map.primal_con_dual_var[ci]
end

function MOI.get(optimizer::DualOptimizer, ::MOI.SolverName)
    return "Dual model with "*MOI.get(optimizer.dual_problem.dual_model, MOI.SolverName())*" attached"
end

function MOI.get(optimizer::DualOptimizer, ::MOI.VariablePrimal, vi::VI)
    return -MOI.get(optimizer.dual_problem.dual_model, 
                    MOI.ConstraintDual(), get_ci_dual_optimizer(optimizer, vi))
end

function MOI.get(optimizer::DualOptimizer, ::MOI.ConstraintDual, 
                 ci::CI{F,S}) where {F <: MOI.AbstractScalarFunction, S <: MOI.AbstractScalarSet}
    return MOI.get(optimizer.dual_problem.dual_model, 
                   MOI.VariablePrimal(), get_vi_dual_problem(optimizer, ci))
end

function MOI.get(optimizer::DualOptimizer, ::MOI.ConstraintDual, 
                 ci::CI{F,S}) where {F <: MOI.AbstractVectorFunction, S <: MOI.AbstractVectorSet}
    return MOI.get.(optimizer.dual_problem.dual_model, 
                    MOI.VariablePrimal(), get_vis_dual_problem(optimizer, ci))
end

function MOI.get(optimizer::DualOptimizer, ::MOI.ConstraintPrimal, 
                 ci::CI{F,S}) where {F <: MOI.AbstractScalarFunction, S <: MOI.AbstractScalarSet}
    primal_ci_constant = get_primal_ci_constant(optimizer, ci)
    # If it has no key than there is no dual constraint
    if !haskey(optimizer.dual_problem.primal_dual_map.primal_con_dual_con, ci)
        return -primal_ci_constant
    end
    ci_dual_problem = get_ci_dual_problem(optimizer, ci)
    ci_dual_optimizer = get_ci_dual_optimizer(optimizer, ci_dual_problem)
    return MOI.get(optimizer.dual_problem.dual_model, MOI.ConstraintDual(), ci_dual_optimizer) - primal_ci_constant
end

function MOI.get(optimizer::DualOptimizer, ::MOI.ConstraintPrimal, 
                 ci::CI{F,S}) where {F <: MOI.AbstractVectorFunction, S <: MOI.AbstractVectorSet}
    # If it has no key than there is no dual constraint
    if !haskey(optimizer.dual_problem.primal_dual_map.primal_con_dual_con, ci)
        # The number of dual variable associated with the primal constraint is the ci dimension
        ci_dimension = length(get_vis_dual_problem(optimizer, ci))
        return zeros(Float64, ci_dimension)
    end
    ci_dual_problem = get_ci_dual_problem(optimizer, ci)
    ci_dual_optimizer = get_ci_dual_optimizer(optimizer, ci_dual_problem)
    return MOI.get(optimizer.dual_problem.dual_model, MOI.ConstraintDual(), ci_dual_optimizer)
end

function MOI.get(optimizer::DualOptimizer, ::MOI.SolveTime) 
    return MOI.get(optimizer.dual_problem.dual_model, MOI.SolveTime())
end

function MOI.get(optimizer::DualOptimizer, ::MOI.TerminationStatus) 
    return dual_status(MOI.get(optimizer.dual_problem.dual_model, MOI.TerminationStatus()))
end

function dual_status(term::MOI.TerminationStatusCode)
    if term == MOI.INFEASIBLE 
        return MOI.DUAL_INFEASIBLE
    elseif term == MOI.DUAL_INFEASIBLE
        return MOI.INFEASIBLE 
    elseif term == MOI.ALMOST_INFEASIBLE
        return MOI.ALMOST_DUAL_INFEASIBLE
    elseif term == MOI.ALMOST_DUAL_INFEASIBLE
        return MOI.ALMOST_INFEASIBLE
    end
    return term
end

# To be added in MOI 0.9.0
# function MOI.get(optimizer::DualOptimizer, ::MOI.ObjectiveValue)
#     return MOI.get(optimizer.dual_optimizer, MOI.DualObjectiveValue())
# end

# function MOI.get(optimizer::DualOptimizer, ::MOI.DualObjectiveValue)
#     return MOI.get(optimizer.dual_optimizer, MOI.ObjectiveValue())
# end

function MOI.get(optimizer::DualOptimizer, ::MOI.ObjectiveValue)
    return MOI.get(optimizer.dual_problem.dual_model, MOI.ObjectiveValue())
end

function MOI.get(optimizer::DualOptimizer, ::MOI.PrimalStatus)
    return MOI.get(optimizer.dual_problem.dual_model, MOI.DualStatus())
end

function MOI.get(optimizer::DualOptimizer, ::MOI.DualStatus)
    return MOI.get(optimizer.dual_problem.dual_model, MOI.PrimalStatus())
end

function MOI.get(optimizer::DualOptimizer, ::MOI.ResultCount)
    return MOI.get(optimizer.dual_problem.dual_model, MOI.ResultCount())
end