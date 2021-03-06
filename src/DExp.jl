# no closure / lifted

Hash = Dict{String, String}

abstract type AbstractScope end

struct Scope <: AbstractScope
    count    :: Ref{Int}
    freevars :: Hash
    bounds   :: Hash
    parent   :: Union{Nothing, AbstractScope}
end

function lookup(d::Hash, k::String)
    get(d, k, nothing)
end

function lookup(d::Scope, k::String) where T
    v = lookup(d.bounds, k)
    v !== nothing && return v
    v = lookup(d.freevars, k)
    v !== nothing && return v
    nothing
end

function new!(scope::Scope)
    Scope(scope.count, Hash(), Hash(), scope)
end

function enter!(scope::Scope, k)
    c = scope.count.x
    scope.count.x = c + 1
    name = "$k._$(string(c, base=32))"
    scope.bounds[k] = name
    name
end

function enter!(scope::Scope, k, v)
    scope.bounds[k] = v
    v
end

function require!(scope::Scope, k::String)
    v = lookup(scope, k)
    v !== nothing && return v
    required_scopes = [scope]
    scope = scope.parent

    while scope !== nothing
        v = lookup(scope, k)
        v !== nothing && begin
            for each in required_scopes
                each.freevars[k] = v
            end
            return v
        end
        push!(required_scopes, scope)
        scope = scope.parent
    end
    throw(NameUnresolved(k))
end

@data DExp begin
    DAssign(reg::String, val::DExp)
    DClosure(freevars::Vector{String}, argnames::Vector{String}, body::DExp)
    DIf(cond::DExp, br1::DExp, br2::DExp)
    DConst{T} :: (v::T) => DExp
    DVar(sym::String)
    DBlock(elts::Vector{DExp})
    DCall(f::DExp, args::Vector{DExp})
    DAttr(subject::DExp, attr::String)
    DList(elts::Vector{DExp})
    DLoc(lineno::Int, colno::Int, val::DExp)
    DStaged(val :: Any)
    DImport(paths::Vector{String}, name::String, actual::String)
    DModule(modname::String, exports::Vector{Tuple{String, String}}, stmts::Vector{DExp})
end

global_scope() = Scope(Ref(0), Dict{String, String}(), Hash(), nothing)

mutable struct ModuleSpec
    name           :: String # for inspect
    path           :: String
    exports        :: Dict{String, String}
    op_prec        :: Dict{String, Int}
    op_asoc        :: Dict{String, Bool}
end



new_module_spec(name::String, path :: String) = ModuleSpec(name, path, Dict{String, String}(), Dict{String, Int}(), Dict{String, Bool}())

macro position_monitor(l, exp)
    quote
        try $exp
        catch e
            if e isa JMLCompilerError
            else
                e = SimpleMessage(string(e))
            end
            throw(Positioned($l.lineno, $l.colno, e))
        end
    end |> esc
end

function scoping_analysis(
    scope::Scope,
    lexp::LExp,
    modules::OrderedDict{String, ModuleSpec},
    curPath::String = "."
)
    JMLPATH::String =
        get(ENV, "JMLPATH") do
            ""
        end
    JMLPATHS = map(string ∘ strip, split(JMLPATH, ";"))
    pushfirst!(JMLPATHS, curPath)

    main = modules["main"]
    if !isa(lexp, LModule)
        lexp = LModule("main", String[], LExp[lexp])
    end

    sa_mod(scope, lexp, main, modules, JMLPATHS)
end


"""
scoping analysis for module
"""
function sa_mod(
    scope::Scope,
    lexp::LExp,
    modulespec::ModuleSpec,
    modules::OrderedDict{String, ModuleSpec},
    JMLPATHS :: Vector{String},
)
    sa(scope, lexp) = sa_mod(scope, lexp, modulespec, modules, JMLPATHS)

    @match lexp begin
        LImport(_) && limport  => import!(limport, false, modulespec, scope, modules, JMLPATHS)
        LStaged(v)             => DStaged(v)
        LAttr(value, attr)     => DAttr(sa(scope, value), attr)
        LList(elts)            => DList([sa(scope, elt) for elt in elts])
        LCall(f, args)         => DCall(sa(scope, f), [sa(scope, arg) for arg in args])
        LBlock(elts)           => DBlock([sa(scope, elt) for elt in elts])
        LVar(s)                => let s = require!(scope, s); DVar(s) end
        LConst(v)              => DConst(v)
        LIf(a, b, c)           => DIf(sa(scope, a), sa(scope, b), sa(scope, c))
        LBin(seq)              => sa(scope, binop_reduce(seq, modulespec.op_prec, modulespec.op_asoc))
        LLoc(l, v)             => DLoc(l.lineno, l.colno, @position_monitor l sa(scope, v))
        LLet(rec, binds, body) =>
            if rec
                ns = new!(scope)
                block = DExp[]
                binds2 :: Vector{Tuple{String, LExp}} = [(enter!(ns, k), v) for (k, v) in binds]
                for (unmangled_name, v) in binds2
                    push!(block, DAssign(unmangled_name, sa(ns, v)))
                end
                push!(block, sa(ns, body))
                DBlock(block)
            else
                ns = new!(scope)
                block :: Vector{DExp} = [
                    DAssign(enter!(ns, k), sa(new!(scope), v)) for (k, v) in binds
                ]
                push!(block, sa(ns, body))
                DBlock(block)
            end
        LFun(args, body) =>
            let ns = new!(scope),
                args = [enter!(ns, arg) for arg in args],
                body = sa(ns, body)
                DClosure(collect(values(ns.freevars)), args, body)
            end

        LModule(modname, args, seq) =>
            let paths = split(modulespec.name, '.'),
                is_current = modname == paths[end],
                modulespec = is_current ? modulespec : begin
                    qualified_name = join([paths..., modname], ".")
                    get!(modules, qualified_name) do
                        new_module_spec(qualified_name, modulespec.path)
                    end
                end,
                scope = is_current ? scope : new!(scope),
                block = [],
                pairs = Dict{String, String}()
                sort!(seq, by=@λ begin
                    LLoc(_, ::LOps) => 1
                    _               => 0
                end) # put LOps to tail

                function analysis_top(each :: LExp)
                    @match each begin
                        LLoc(l, a) =>
                                let f = @position_monitor l analysis_top(a)
                                    () -> DLoc(l.lineno, l.colno, @position_monitor l f())
                                end
                        LDefine(s, v) =>
                                let ss = enter!(scope, s),
                                    _ = pairs[s] = ss,
                                    v = v
                                    () ->
                                    let ns = new!(scope)
                                        DAssign(ss, sa_mod(ns, v, modulespec, modules, JMLPATHS))
                                    end
                                end
                        LForeign(paths, name) =>
                                let ss = enter!(scope, name)
                                    () -> DImport(paths, name, ss)
                                end
                        LImport(_) && limport =>
                                let a = import!(limport, true, modulespec, scope, modules, JMLPATHS)
                                    () -> a
                                end
                        LInfix(opname, prec, is_right) =>
                                let _ = modulespec.op_prec[opname] = prec,
                                    _ = modulespec.op_asoc[opname] = is_right
                                    () -> DConst(nothing)
                                end
                        LOps(names) =>
                                let _ = for each in names
                                            modulespec.exports[each] = require!(scope, each)
                                        end
                                    () -> DConst(nothing)
                                end
                        a => let a = a; () -> sa_mod(scope, a, modulespec, modules, JMLPATHS) end
                    end
                end

                let fs = map(analysis_top, seq)
                    for each in fs
                        push!(block, each())
                    end
                    DModule(modname, [(a, b) for (a, b) in pairs] , block)
                end
            end
    end
end

function import!(
    limport::LImport,
    is_top_level::Bool,
    modulespec :: ModuleSpec,
    scope::Scope,
    modules::OrderedDict{String, ModuleSpec},
    JMLPATHS::Vector{String}
)
    @when LImport(is_qual, paths, name) = limport begin
        qualified_name = join([paths..., name], '.')
        for JMLPATH in JMLPATHS # start loop
            path = joinpath(JMLPATH, paths..., name * ".jml")
            m = get(modules, qualified_name, nothing)
            if m === nothing
                (m, src_code) =
                    try open(path) do f
                        src_code = read(f, String)
                        new_module_spec(qualified_name, path), src_code
                        end
                    catch e
                        continue
                    end
                try
                    rexp = runparser(src_code, :rexp)
                catch e
                    base = SimpleMessage("parser failed for $path")
                    if e isa ParserFailed
                        base = ComposeExc(
                            SimpleMessage(e.msg),
                            base
                        )
                    end
                    throw(
                        ComposeExc(
                            ModulePathNotFound(qualified_name),
                            base
                        )
                    )
                end
                modules[qualified_name] = m
                sa_mod(global_scope(), to_lexp(rexp), m, modules, JMLPATHS)
            end
            if is_qual
                enter!(scope, name)
            else
                for (k, v) in m.exports
                    enter!(scope, k, v)
                end
            end
            if is_top_level
                for (each, _) in m.exports
                    if haskey(m.op_prec, each)
                        modulespec.op_prec[each] = m.op_prec[each]
                        modulespec.op_asoc[each] = m.op_asoc[each]
                    end
                end
            end
            return DConst(nothing)
        end # end loop
        throw(ModulePathNotFound(qualified_name))
    @otherwise
        throw(SimpleMessage("hmmm, you encountered an internal error."))
    end
end