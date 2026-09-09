module test_completions

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.URIs2

include("setup.jl")
include("jsjl-utils.jl")

module lowering_module end

function get_cursor_bindings(
        fi::JETLS.FileInfo, b::Int;
        context_module::Module = lowering_module,
        soft_scope::Bool = false,
        world::UInt = Base.get_world_counter()
    )
    st0 = JETLS.build_syntax_tree(fi)
    cb = JETLS.cursor_bindings(st0, b, context_module, world; soft_scope)
    return isnothing(cb) ? [] : cb
end
function get_cursor_bindings(marked_text::AbstractString; kwargs...)
    text, positions = JETLS.get_text_and_positions(marked_text)
    fi = JETLS.FileInfo(#=version=#0, text, @__FILE__)
    b = JETLS.xy_to_offset(fi, positions[1])
    return get_cursor_bindings(fi, b; kwargs...)
end

function get_local_completions(s::AbstractString, b::Int)
    uri = JETLS.URIs2.filepath2uri(@__FILE__)
    fi = JETLS.FileInfo(#=version=#0, s, @__FILE__)
    return map(get_cursor_bindings(fi, b)) do ((bi, st, dist))
        JETLS.to_completion(bi, st, dist, uri, fi)
    end
end

# Test that completion vector contains CompletionItems with all of `expected`
# labels (with `kind` if provided).
# Note that completions are filtered on the client side, so we expect a completion
# for "x" in "let x = 1; abc|; end"
function cv_has(cs::Vector{CompletionItem}, expected; kind=nothing)
    cdict = Dict(zip(map(c -> c.label, cs), cs))
    for e in expected
        if e isa String
            name = e
            f = nothing
        else
            f, name = e
        end
        c = get(cdict, name, nothing)
        @test !isnothing(c)
        if !isnothing(c)
            if !isnothing(kind)
                @test JETLS.completion_is(c, kind)
            end
            isnothing(f) || f(c)
        end
    end
end

# Test that completion vector does not contain any of `unexpected` labels.
function cv_nhas(cs::Vector{CompletionItem}, unexpected)
    cnames = Set(map(cs -> cs.label, cs))
    for ne in unexpected
        @test !(String(ne) in cnames)
    end
end

function with_completion(f, text::String; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    for (i, pos) in enumerate(positions)
        cv = get_local_completions(clean_code, JETLS.xy_to_offset(clean_code, pos, @__FILE__))
        f(i, cv)
    end
end

# shorthand for testing single cursor completion
function test_single_cv(
        code::String, expected::Vector{String};
        unexpected::Vector{String} = String[], kind = nothing,
        matcher::Regex = r"│", kwargs...
    )
    @assert count(matcher, code) == 1 "test_single_cv requires exactly one cursor marker"
    with_completion(code; matcher, kwargs...) do _, cv
        cv_has(cv, expected; kind)
        cv_nhas(cv, unexpected)
    end
end

@testset "sanity" begin
    snippets = [
        "let x = 1;                  │  end",
        "let; (y,(x,z)) = (2,(1,3))  │  end",
        "function f(x);              │  end",
        "function f(x...);           │  end",
        "function f(a::x) where x;   │  end",
        "let; global x;              │  end",
        "for x in 1:10;              │  end",
        "map([]) do x;               │  end",
        "(x ->                       │   1)",
    ]
    for code in snippets
        test_single_cv(code, ["x"])
    end
end

@testset "subtree lowering within modules" begin
    code = """
    module M
        │
        export foo

        function foo(x)
            y = 1
            z = 2
            │
        end

        module M2
            function foo(a)
                b = 1
                c = 2
                │
            end
        end
    end
    """
    cnt = Ref(0)
    with_completion(code) do i, cv
        if i == 1
            cv_nhas(cv, ["a", "b", "c", "x", "y", "z"])
            cnt[] += 1
        elseif i == 2
            cv_has(cv, ["x", "y", "z"], kind=:local)
            cv_nhas(cv, ["a", "b", "c"])
            cnt[] += 1
        elseif i == 3
            cv_has(cv, ["a", "b", "c"], kind=:local)
            cv_nhas(cv, ["x", "y", "z"])
            cnt[] += 1
        end
    end
    @test cnt[] == 3
end

@testset "nested and adjacent scopes" begin
    let code = "let; let; x = 1;   end;        │ let;          end; end"; test_single_cv(code, String[], unexpected=["x"]); end
    let code = "let; let; x = 1;   end;          let;        │ end; end"; test_single_cv(code, String[], unexpected=["x"]); end
    let code = "let; let;        │ end; x = 1;   let;          end; end"; test_single_cv(code, String[], unexpected=["x"]); end
    let code = "let; let;          end; x = 1;   let;        │ end; end"; test_single_cv(code, ["x"]); end
    let code = "let; let;        │ end;          let; x = 1;   end; end"; test_single_cv(code, String[], unexpected=["x"]); end
    let code = "let; let;          end;        │ let; x = 1;   end; end"; test_single_cv(code, String[], unexpected=["x"]); end
end

@testset "globals in local scope, shadowing" begin
    # global decl should be contained
    let code = "function f(g); │ let;   global g;   end;   end"
        test_single_cv(code, ["g"], kind=:argument)
    end
    let code = "function f(g);   let;   global g; │ end;   end"
        test_single_cv(code, ["g"], kind=:global)
    end
    let code = "function f(g);   let;   global g;   end; │ end"
        test_single_cv(code, ["g"], kind=:argument)
    end
    # global doesn't follow the "before-the-cursor" rule
    let code = "function f(g);   let; │ global g;   end;   end"
        test_single_cv(code, ["g"], kind=:global)
    end

    # local shadowing global
    let code = """
        function f()
            global g = 1; │
            let │
                let
                    local g
                    │
                    let; │ end
                end
            end
        end
        """

        cnt = Ref(0)
        with_completion(code) do i, cv
            if i == 1
                cv_has(cv, ["g"], kind=:global)
                cnt[] += 1
            elseif i == 2
                cv_has(cv, ["g"], kind=:global)
                cnt[] += 1
            elseif i == 3
                cv_has(cv, ["g"], kind=:local)
                cnt[] += 1
            elseif i == 4
                cv_has(cv, ["g"], kind=:local)
                cnt[] += 1
            end
        end
        @test cnt[] == 4
    end

    # global/local decl below cursor
    let code = """
        function f(x)
            let
                │
                global x
                x = 1
                let
                    x = 2 # otherwise we would filter this completion out
                    │
                    local x
                    x
                end
            end
        end
        """
        cnt = Ref(0)
        with_completion(code) do i, cv
            if i == 1
                cv_has(cv, ["x"], kind=:global)
                cnt[] += 1
            elseif i == 2
                # broken. JuliaLowering bug?
                # cv_has(cv, ["x"], kind=:local)
                cnt[] += 1
            end
        end
        @test cnt[] == 2
    end
end

@testset "cursor in new symbol" begin
    # Don't suggest a symbol which appears for the first time right before the cursor
    let code = "function f(); global g1; g2│; end"
        test_single_cv(code, ["g1"], unexpected=["g2"])
    end
    let code = "function f(); global g1; g│2; end"
        test_single_cv(code, ["g1"], unexpected=["g", "g2"])
    end
    let code = "function f(); global g1; │g2; end"
        test_single_cv(code, ["g1"], unexpected=["g2"])
    end
end

@testset "completion for code including macros" begin
    code = """
    function foo(x)
        │
        return @inline typeof(x)
    end
    """
    test_single_cv(code, ["x"])
end

@testset "local completion for method with docstring" begin
    let code = """
        \"\"\"
        docstring above
        \"\"\"
        function foo(x, y)
            z = x + y
            │
        end
        """
        test_single_cv(code, ["x", "y", "z"])
    end
    let code = """
        @doc \"\"\"
        docstring above
        \"\"\"
        function foo(x, y)
            z = x + y
            │
        end
        """
        test_single_cv(code, ["x", "y", "z"])
    end
end

# completion for type declared locals
@testset "completion for type declared locals" begin
    code = """
    function foo(x::T) where T
        local y::T = x
        │
    end
    """
    cnt = Ref(0)
    with_completion(code) do i, cv
        if i == 1
            check(c) = @test c.labelDetails.detail == "::T"
            cv_has(cv, [(check, "y")], kind=:local)
            cnt[] += 1
        end
    end
    @test cnt[] == 1
end

@testset "local completion for incomplete code shouldn't crash" begin
    let code = """
        function fo│
        """
        @expect_jl_err test_single_cv(code, String[])
    end
    let # XXX somehow wrapping within `module A ... end` is necessary to get `xx` completion for this incomplete code
        code = """
        module A
        function foo(xx, y=x│)
        end
        """
        test_single_cv(code, ["xx"], kind=:local)
    end
end

# get_completion_items
# ====================

function with_completion_request(
        tester, text::AbstractString;
        context::Union{Nothing, CompletionContext} = nothing,
        kwargs...
    )
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter, server)
            JETLS.cache_file_info!(server, uri, 1, clean_code)
            JETLS.cache_saved_file_info!(server.state, uri, clean_code)
            JETLS.request_analysis!(server, uri, #=invalidate=#false; wait=true, notify_diagnostics=false)
            for (i, pos) in enumerate(positions)
                params = CompletionParams(;
                    textDocument = TextDocumentIdentifier(; uri),
                    position = pos,
                    context = context)
                (; raw_res) = writereadmsg(CompletionRequest(;
                        id = id_counter[] += 1,
                        params = params))
                tester(i, raw_res.result, uri)
            end
        end
    end
end

# Lightweight alternative to `with_completion_request`: skips the full
# `request_analysis!` setup, so it works for tests against names from
# `Main`/`Base`/`Core` and for local/keyword/latex/emoji completions.
# Pass a `context_module` to keep test bindings out of `Main`; the `state`
# threaded into the tester lets tests exercise `resolve_completion_item`.
function with_completion_items(
        tester, text::AbstractString;
        context::Union{Nothing, CompletionContext} = nothing,
        context_module::Union{Nothing, Module} = nothing,
        kwargs...
    )
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    uri = filepath2uri(@__FILE__)
    state = JETLS.ServerState()
    state.init_params = InitializeParams(;
        processId = getpid(),
        rootUri = nothing,
        capabilities = ClientCapabilities(;
            textDocument = TextDocumentClientCapabilities(;
                completion = CompletionClientCapabilities(;
                    completionItem = ClientCompletionItemOptions(;
                        resolveSupport = ClientCompletionItemResolveOptions(;
                            properties = ["documentation", "detail", "kind", "labelDetails"])
                    )))))
    fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
    JETLS.store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    snapshot = JETLS.get_document_snapshot(state, uri)::JETLS.DocumentSnapshot
    for pos in positions
        items, isIncomplete = JETLS.get_completion_items(state, uri, snapshot, pos, context;
            context_module)
        tester((; result = (; items, isIncomplete), state, uri))
    end
end

@testset "get_completion_items" begin
    program = """
     module Foo
        struct Bar
            x::Int
        end
        function getx(bar::Bar)
            out = bar.x
            │
            return out
        end

        macro weirdmacro(x::Symbol, v)
            name = Symbol(string(x, "_var"))
            return :(\$(esc(name)) = \$v; internal_to_macro = 1)
        end
        function foo(x)
            @weirdmacro y 1
            @timed from_timed = 1
            │ # show `y_var` ideally
            return @inline typeof(y_var)
        end

        baremodule ModuleCompletion
        const xxx = nothing
        end
        function dot_completion_test(xarg)
            ModuleCompletion.x│
            xarg.x│
        end

        function str_macro_test()
            tex│
        end
    end # module Foo
    """

    cnt = Ref(0)
    with_completion_request(program) do i, result, _
        items = result.items
        if i == 1
            @test any(items) do item
                item.label == "bar"
            end
            @test any(items) do item
                item.label == "out"
            end
            @test any(items) do item
                item.label == "Bar"
            end
            @test any(items) do item
                item.label == "sin"
            end
            cnt[] += 1
        elseif i == 2
            @test any(items) do item
                item.label == "foo"
            end
            @test any(items) do item
                item.label == "x"
            end
            @test !any(items) do item
                item.label == "y"
            end
            @test any(items) do item
                item.label == "y_var"
            end
            @test any(items) do item
                item.label == "from_timed"
            end
            @test !any(items) do item
                contains(item.label, "internal_to_macro") ||
                    contains(item.label, "#")
            end
            cnt[] += 1
        elseif i == 3
            # `dot_completion_test`: dot-prefixed global completion
            xxxidx = findfirst(item->item.label=="xxx", items)
            @test !isnothing(xxxidx)
            coreidx = findfirst(item->item.label=="Core", items) # Core is still available for baremodule
            @test !isnothing(xxxidx)
            @test items[xxxidx].sortText < items[coreidx].sortText # prioritize showing names defined within the completion context module
            @test isnothing(findfirst(item->item.label=="getx", items))
            @test isnothing(findfirst(item->item.label=="foo", items))
            @test isnothing(findfirst(item->item.label=="xarg", items)) # local completion should be disabled
            cnt[] += 1
        elseif i == 4
            # `dot_completion_test`: dot-prefixed global completion
            # https://github.com/aviatesk/JETLS.jl/issues/389
            @test isempty(items) # completions should be disabled if the prefix type/value is unknown
            cnt[] += 1
        elseif i == 5
            # `str_macro_test`: string macro case
            @test any(items) do item
                item.label == "text\"\"" &&
                item.data isa GlobalCompletionData && item.data.name == "@text_str"
            end
            cnt[] += 1
        end
    end
    @test cnt[] == 5
end

@testset "local completion for methods with `@nospecialize`" begin
    text = """
    function foo(@nospecialize(xxx), @nospecialize(yyy))
        y│
    end
    """

    context = CompletionContext(; triggerKind = CompletionTriggerKind.Invoked)
    cnt = Ref(0)
    with_completion_items(text; context) do (; result)
        items = result.items
        @test any(items) do item
            item.label == "yyy"
        end
        cnt[] += 1
    end
    @test cnt[] == 1
end

# completion for empty program should not crash
@testset "empty completion" begin
    let text = "│"
        cnt = Ref(0)
        with_completion_items(text) do (; result)
            items = result.items
            # should not crash and return something
            @test length(items) > 0
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = "\n\n\n│"
        cnt = Ref(0)
        with_completion_items(text) do (; result)
            items = result.items
            # should not crash and return something
            @test length(items) > 0
            cnt[] += 1
        end
        @test cnt[] == 1
    end
end

module custom_props_fixture
    struct CustomProps
        x::Int
    end
    Base.propertynames(::CustomProps) = (:x_int, :x_float32, :x_float64)
    function Base.getproperty(cp::CustomProps, name::Symbol)
        if name === :x_int
            return getfield(cp, :x)
        elseif name === :x_float32
            return Float32(getfield(cp, :x))
        elseif name === :x_float64
            return Float64(getfield(cp, :x))
        else
            throw(ArgumentError(lazy"CustomProps does not accept property name $name"))
        end
    end
end

# `propertynames`/`getfield` mismatch fixture for property completion tests
module broken_props_fixture
    struct BrokenProps end
    Base.propertynames(::BrokenProps) = (:no_such_field,)
end

# Per-field docstring fixture for property-completion field-doc tests.
module field_doc_props_fixture
    """Documented struct with per-field docstrings."""
    struct DocStruct
        """The x field — an integer."""
        x::Int
        """The y field — a string."""
        y::String
        z::Float64  # no field doc
    end
end

@testset "property completion" begin
    dot_context = CompletionContext(;
        triggerKind = CompletionTriggerKind.TriggerCharacter,
        triggerCharacter = ".")

    only_props(items) = filter(items) do it
        ld = it.labelDetails
        ld !== nothing && ld.description == "property"
    end

    # `r.│` on a `Regex`-typed parameter should offer `Regex`'s properties.
    # Type detail is filled in only after a resolve request — the initial
    # response carries `PropertyCompletionData` and no `detail`.
    let text = """
        function bar(r::Regex)
            r.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result, state)
            props = only_props(result.items)
            labels = Set(it.label for it in props)
            @test labels == Set(String.(fieldnames(Regex)))
            for it in props
                @test it.kind === CompletionItemKind.Property
                @test it.labelDetails.detail === nothing
                @test it.data isa JETLS.PropertyCompletionData
            end
            pattern_item = first(filter(it -> it.label == "pattern", props))
            resolved = JETLS.resolve_completion_item(state, pattern_item)
            @test resolved.labelDetails.detail !== nothing
            @test occursin("String", resolved.labelDetails.detail)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        function func(c::Bool, r::Regex)
            try
                r.│
                if c
                    return nothing
                end
            catch
            end
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result)
            labels = Set(it.label for it in only_props(result.items))
            @test labels == Set(String.(fieldnames(Regex)))
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        function func(c::Bool, r::Regex)
            try
                out = r.│
                if c
                    return nothing
                end
            catch
            end
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result)
            labels = Set(it.label for it in only_props(result.items))
            @test labels == Set(String.(fieldnames(Regex)))
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Untyped prefix: no useful type to query, so no property completions.
    let text = """
        function bar(x)
            x.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result)
            @test isempty(only_props(result.items))
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # A `Union{}`-typed prefix that isn't a resolvable global const (here a
    # `Bottom`-returning call): the `resolve_global_const` fallback yields `nothing`,
    # so no properties are offered and we don't fall through to global/local completions.
    let text = """
        function bar()
            error("unreachable").│
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result)
            @test isempty(result.items)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # A `Union{}`-typed prefix that *is* a resolvable global const recovers module completions
    # via the `resolve_global_const` fallback. Here `Base` sits in a dead branch, so its
    # inferred type is `Union{}`, yet `Base.` still completes.
    let text = """
        function bar()
            c = false
            if c
                Base.│
            end
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result)
            labels = Set(it.label for it in result.items)
            @test "isexpr" in labels   # Base member → module completion fired
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # `r.│` sitting inside a call's argument list (parser inserts an error
    # in the property-name slot, so the dot subtree must be repaired before
    # lowering can resolve `r`'s type).
    let text = """
        function bar(r::Regex)
            g(r.pattern, r.│)
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result)
            labels = Set(it.label for it in only_props(result.items))
            @test labels == Set(String.(fieldnames(Regex)))
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Union prefix offers the union of property names, and each property's
    # resolved type detail is the union of its per-component types.
    let text = """
        function bar(p::Union{Pair{Symbol,Int}, Pair{Symbol,String}})
            p.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result, state)
            props = only_props(result.items)
            labels = Set(it.label for it in props)
            @test labels == Set(["first", "second"])
            # Resolve `first` → `Symbol` (same on both sides).
            first_item = first(filter(it -> it.label == "first", props))
            resolved_first = JETLS.resolve_completion_item(state, first_item)
            @test occursin("Symbol", resolved_first.labelDetails.detail)
            # Resolve `second` → `Union{Int,String}` (merged from both sides).
            second_item = first(filter(it -> it.label == "second", props))
            resolved_second = JETLS.resolve_completion_item(state, second_item)
            @test occursin("$Int", resolved_second.labelDetails.detail)
            @test occursin("String", resolved_second.labelDetails.detail)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # `Union{T, Nothing}`: `T`'s properties are still offered, and their
    # resolved type detail isn't polluted by the `Nothing` side.
    let text = """
        function bar(r::Union{Regex, Nothing})
            r.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text; context=dot_context) do (; result, state)
            props = only_props(result.items)
            labels = Set(it.label for it in props)
            @test labels == Set(String.(fieldnames(Regex)))
            pattern_item = first(filter(it -> it.label == "pattern", props))
            resolved = JETLS.resolve_completion_item(state, pattern_item)
            @test resolved.labelDetails.detail !== nothing
            @test occursin("String", resolved.labelDetails.detail)
            @test !occursin("Union{}", resolved.labelDetails.detail)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        function test_custom_props(cp::CustomProps)
            cp.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text;
                context=dot_context,
                context_module=custom_props_fixture,
            ) do (; result, state)
            props = only_props(result.items)
            labels = Set(it.label for it in props)
            @test labels == Set(("x_int", "x_float32", "x_float64"))
            @test all(p->isnothing(p.labelDetails.detail), props)
            i = findfirst(p->p.label=="x_float32", props)
            @test !isnothing(i)
            resolved = JETLS.resolve_completion_item(state, props[i])
            @test resolved.labelDetails.detail == " ::Float32"
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # A `propertynames` overload that name's `getproperty` can't honor:
    # the item is still offered, and its resolved type detail surfaces as `::Union{}`.
    let text = """
        function bar(x::BrokenProps)
            x.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text;
                context=dot_context,
                context_module=broken_props_fixture,
            ) do (; result, state)
            props = only_props(result.items)
            @test length(props) == 1
            @test props[1].label == "no_such_field"
            @test props[1].labelDetails.detail === nothing
            resolved = JETLS.resolve_completion_item(state, props[1])
            @test resolved.labelDetails.detail == " ::Union{}"
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Resolved completion documentation includes the per-field docstring
    # for fields that carry one, and stays at the bare type-signature code
    # fence for undocumented fields.
    let text = """
        function bar(s::DocStruct)
            s.│
        end
        """
        cnt = Ref(0)
        with_completion_items(text;
                context=dot_context,
                context_module=field_doc_props_fixture,
            ) do (; result, state)
            props = only_props(result.items)
            x_item = first(filter(it -> it.label == "x", props))
            resolved_x = JETLS.resolve_completion_item(state, x_item)
            x_value = resolved_x.documentation.value
            @test occursin("s.x :: $Int", x_value)
            @test occursin("The x field", x_value)

            z_item = first(filter(it -> it.label == "z", props))
            resolved_z = JETLS.resolve_completion_item(state, z_item)
            z_value = resolved_z.documentation.value
            @test occursin("s.z :: Float64", z_value)
            @test !occursin("---", z_value)  # no doc section appended
            cnt[] += 1
        end
        @test cnt[] == 1
    end
end

# Script analysis materializes non-concretized global `const`s as
# `JET.AbstractBindingState` placeholders in the analyzed module's namespace;
# completion resolution must classify and document the analyzed binding instead
# of leaking the placeholder's auto-generated summary.
module completion_binding_state_fixture end
Core.eval(completion_binding_state_fixture, Expr(:const, :virtualized_str_const,
    JETLS.JET.AbstractBindingState(true, false, String)))
Core.eval(completion_binding_state_fixture, Expr(:const, :virtualized_func_alias,
    JETLS.JET.AbstractBindingState(true, false, Core.Const(cos))))
Core.eval(completion_binding_state_fixture, Expr(:const, :virtualized_documented,
    JETLS.JET.AbstractBindingState(true, false, String)))
Core.eval(completion_binding_state_fixture,
    :(Base.@doc "Virtualized binding docs." virtualized_documented))

@testset "global completion with script-analysis binding state" begin
    cnt = Ref(0)
    with_completion_items("virtualized_│";
            context_module = completion_binding_state_fixture) do (; result, state)
        function resolve_label(label::String)
            item = only(filter(it -> it.label == label, result.items))
            return JETLS.resolve_completion_item(state, item)
        end
        resolved = resolve_label("virtualized_str_const")
        @test resolved.detail == "[constant variable]"
        @test resolved.kind == CompletionItemKind.Constant
        @test resolved.documentation === nothing
        resolved = resolve_label("virtualized_func_alias")
        @test resolved.detail == "[function]"
        @test resolved.kind == CompletionItemKind.Function
        resolved = resolve_label("virtualized_documented")
        @test resolved.documentation isa MarkupContent
        @test occursin("Virtualized binding docs.", resolved.documentation.value)
        @test !occursin("AbstractBindingState", resolved.documentation.value)
        cnt[] += 1
    end
    @test cnt[] == 1
end

@testset "macro completion" begin
    # `@`-mark should trigger completion of macro names
    let text = """
        function foo(xxx, yyy)
            @│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "@")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "@nospecialize" &&
                item.textEdit.newText == "@nospecialize"
            end
            @test !any(items) do item
                item.label == "foo" || item.label == "xxx" || item.label == "yyy"
            end
            # keywords should NOT appear in macro context
            @test !any(items) do item
                item.label == "function"
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # completion for macro names
    let text = """
        function foo(xxx, yyy)
            @no│
        end
        """
        context = CompletionContext(; triggerKind = CompletionTriggerKind.Invoked)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "@nospecialize" &&
                item.textEdit.newText == "@nospecialize"
            end
            @test !any(items) do item
                item.label == "foo" || item.label == "xxx" || item.label == "yyy"
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # completion within macro call context
    let text = """
        function foo(xxx, yyy)
            @nospecialize xxx y│
        end
        """
        context = CompletionContext(; triggerKind = CompletionTriggerKind.Invoked)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "yyy"
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # allow `nospecia│` complete to `@nospecialize`
    let text = """
        function foo(xxx, yyy)
            nospecia│
        end
        """
        context = CompletionContext(; triggerKind = CompletionTriggerKind.Invoked)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "@nospecialize" &&
                item.textEdit.newText == "@nospecialize"
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end
end

# Latex&emoji
# ===========

function test_backslash_offset(code::String, expected_result)
    text, positions = JETLS.get_text_and_positions(code)
    @assert length(positions) == 1 "test_backslash_offset requires exactly one cursor marker"

    server = JETLS.Server()
    filename = abspath("test_backslash.jl")
    uri = filename2uri(filename)
    fi = JETLS.cache_file_info!(server, uri, 1, text)

    result = JETLS.get_backslash_offset(fi, positions[1])
    @test result == expected_result
    return result
end

@testset "get_backslash_offset" begin
    # Example 1: Current token is backslash
    let code = "\\│"
        test_backslash_offset(code, (1, false))
    end
    let code = "  \\│"
        test_backslash_offset(code, (sizeof("  \\"), false))
    end

    # Example 2: Previous token is backslash
    let code = "\\alpha│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\beta│"
        test_backslash_offset(code, (1, false))
    end
    let code = "  \\gamma│"
        test_backslash_offset(code, (sizeof("  \\"), false))
    end
    let code = "\\ │"
        test_backslash_offset(code, nothing)
    end
    let code = "\\  │"
        test_backslash_offset(code, nothing)
    end

    # Example 3: Backslash followed by colon, then cursor
    let code = "\\:│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:a│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:abc│"
        test_backslash_offset(code, (1, true))
    end
    let code = "  \\:test│"
        test_backslash_offset(code, (sizeof("  \\"), true))
    end

    # Example 4: No relevant backslash (should return nothing)
    let code = "abc│"
        test_backslash_offset(code, nothing)
    end
    let code = "│"
        test_backslash_offset(code, nothing)
    end
    let code = "│\\alpha"
        test_backslash_offset(code, nothing)
    end
    let code = "\\alpha beta│"
        test_backslash_offset(code, nothing)
    end
    let code = "\\alpha beta gamma│"
        test_backslash_offset(code, nothing)
    end
    let code = "\"\\alpha\"│"
        test_backslash_offset(code, nothing)
    end
    let code = "\\:a b│"
        test_backslash_offset(code, nothing)
    end

    # Multiple backslashes - should find the most recent one
    let code = "\\alpha \\beta│"
        test_backslash_offset(code, (sizeof("\\alpha \\"), false))
    end
    let code = "\\alpha \\beta \\gamma│"
        test_backslash_offset(code, (sizeof("\\alpha \\beta \\"), false))
    end

    # In various syntactic contexts
    let code = "f(\\alpha│)"
        test_backslash_offset(code, (sizeof("f(\\"), false))
    end
    let code = "[\\beta│]"
        test_backslash_offset(code, (sizeof("[\\"), false))
    end
    let code = "{\\gamma│}"
        test_backslash_offset(code, (sizeof("{\\"), false))
    end

    # With newlines
    let code = "x = 1\n\\alpha│"
        test_backslash_offset(code, (sizeof("x = 1\n\\"), false))
    end
    let code = "function f()\n    \\beta│\nend"
        test_backslash_offset(code, (sizeof("function f()\n    \\"), false))
    end

    # Complex expressions
    let code = "f(x) = x^2 + \\sigma│"
        test_backslash_offset(code, (sizeof("f(x) = x^2 + \\"), false))
    end
    let code = "result = compute(\\theta│, y)"
        test_backslash_offset(code, (sizeof("result = compute(\\"), false))
    end

    # LaTeX-like sequences
    let code = "\\alpha│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\sum│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\infty│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\mathbb│"
        test_backslash_offset(code, (1, false))
    end

    # Special colon cases
    let code = "\\:heart│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:smile│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:+1│"
        test_backslash_offset(code, (1, true))
    end

    # Unicode characters in code before backslash
    let code = "α = 1; \\beta│"
        test_backslash_offset(code, (sizeof("α = 1; \\"), false))
    end
    let code = "# 测试\n\\gamma│"
        test_backslash_offset(code, (sizeof("# 测试\n\\"), false))
    end

    # Boundary conditions
    let code = "\\│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\a│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\:│"
        test_backslash_offset(code, (1, true))
    end
    let code = "code; \\│"
        test_backslash_offset(code, (sizeof("code; \\"), false))
    end

    # Real-world usage patterns
    let code = "E = mc^2 + \\hbar│"
        test_backslash_offset(code, (sizeof("E = mc^2 + \\"), false))
    end
    let code = "function hermite(n, x)\n    return \\psi│\nend"
        test_backslash_offset(code, (sizeof("function hermite(n, x)\n    return \\"), false))
    end
    let code = "struct Particle\n    momentum::\\vec│\nend"
        test_backslash_offset(code, (sizeof("struct Particle\n    momentum::\\"), false))
    end
    let code = "[\\theta│ for i in 1:n]"
        test_backslash_offset(code, (sizeof("[\\"), false))
    end
    let code = "angle = \\phi│"
        test_backslash_offset(code, (sizeof("angle = \\"), false))
    end

    # within comment/string scope
    let code = "# this is a single line comment \\phi│"
        test_backslash_offset(code, (sizeof("# this is a single line comment \\"), false))
    end
    let code = "# this is a single line comment \\:│"
        test_backslash_offset(code, (sizeof("# this is a single line comment \\"), true))
    end
    let code = "#=\nthis is a multi line comment \\phi│\n=#"
        test_backslash_offset(code, (sizeof("#=\nthis is a multi line comment \\"), false))
    end
    let code = "\"\\phi│\""
        test_backslash_offset(code, (sizeof("\"\\"), false))
    end
end

@testset "Latex/emoji completion" begin
    # `\`-mark should trigger latex completion
    let text = """
        function foo(α, β)
            \\│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "\\")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "\\alpha"
            end
            @test !any(items) do item
                item.label == "foo" || # should not include global completions
                item.label == "β"      # should not include local completions
            end
            # keywords should NOT appear in latex/emoji completion context
            @test !any(items) do item
                item.label == "function"
            end
            @test result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        function foo(α, β)
            \\:│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ":")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "\\:pizza:"
            end
            @test !any(items) do item
                item.label == "foo" || # should not include global completions
                item.label == "α"   || # should not include local completions
                item.label == "β"   || # should not include local completions
                item.label == "alpha" # should not even include LaTeX completions
            end
            @test result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # server-side prefix filtering (aviatesk/JETLS.jl#821): clients like Zed/Helix
    # build their filter query from word characters only, so keys containing
    # `\`/`^`/`:` must be narrowed down by the server
    let text = """
        function foo(α, β)
            \\^│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "^")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "\\^a"
            end
            @test !any(items) do item
                item.label == "\\alpha" # `\alpha` does not contain the typed `^`
            end
            @test result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # filtering is case-insensitive and subsequence-based, so missing characters
    # are tolerated as long as the typed characters appear in order
    let text = """
        function foo(α, β)
            \\gama│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerForIncompleteCompletions)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            labels = Set(item.label for item in result.items)
            @test "\\gamma" in labels
            @test "\\Gamma" in labels
            @test result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        function foo(α, β)
            \\alp│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerForIncompleteCompletions)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "\\alpha"
            end
            @test !any(items) do item
                item.label == "\\beta" ||
                item.label == "\\:pizza:"
            end
            @test result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        function foo(α, β)
            \\:piz│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerForIncompleteCompletions)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test any(items) do item
                item.label == "\\:pizza:"
            end
            @test !any(items) do item
                item.label == "\\:smile:"
            end
            @test result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # `^` outside a backslash context (e.g. the exponentiation operator) should
    # not pop up any completions
    let text = """
        function foo(α, β)
            α^│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "^")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            @test isempty(result.items)
            @test !result.isIncomplete
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # ... but a manual invocation right after `^` still gives normal completions
    let text = """
        function foo(α, β)
            α^│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.Invoked)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            @test any(result.items) do item
                item.label == "β"
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end
end

# method signature completions
# ============================

@testset "extract_param_text" begin
    function parse_param(s::AbstractString)
        call = JS.parsestmt(JS.SyntaxTree, "f($s)")
        return JS.children(call)[2]
    end

    let p = parse_param("x")
        @test JETLS.extract_param_text(p) == "x"
    end
    let p = parse_param("x::Int")
        @test JETLS.extract_param_text(p) == "x::Int"
    end
    let p = parse_param("::Nothing")
        @test JETLS.extract_param_text(p) === "::Nothing"
    end
    let p = parse_param("x::Vector{Int}")
        @test JETLS.extract_param_text(p) == "x::Vector{Int}"
    end
end

@testset "make_insert_text" begin
    @testset "use_snippet=true" begin
        let msig = "sin(x::Number)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:x::Number}"
            @test JETLS.make_insert_text(msig, 1, true) === nothing
        end
        let msig = "filter(f, itr)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:f}, \${2:itr}"
            @test JETLS.make_insert_text(msig, 1, true) == "\${1:itr}"
            @test JETLS.make_insert_text(msig, 2, true) === nothing
        end
        let msig = "foo(a, b, c)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:a}, \${2:b}, \${3:c}"
            @test JETLS.make_insert_text(msig, 1, true) == "\${1:b}, \${2:c}"
            @test JETLS.make_insert_text(msig, 2, true) == "\${1:c}"
            @test JETLS.make_insert_text(msig, 3, true) === nothing
        end
        let msig = "foo(a, b=1)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:a}"
            @test JETLS.make_insert_text(msig, 1, true) === nothing
        end
        let msig = "foo(a, args...)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:a}, \${2:args...}"
            @test JETLS.make_insert_text(msig, 1, true) == "\${1:args...}"
            @test JETLS.make_insert_text(msig, 2, true) === nothing
        end
        let msig = "filter(f, a::Array{T, N}) where {T, N}"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:f}, \${2:a::Array{T, N\\}}"
            @test JETLS.make_insert_text(msig, 1, true) == "\${1:a::Array{T, N\\}}"
            @test JETLS.make_insert_text(msig, 2, true) === nothing
        end
        let msig = "foo(x::T) where T where S"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:x::T}"
        end
        # anonymous typed parameters
        let msig = "foo(::Nothing)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:::Nothing}"
            @test JETLS.make_insert_text(msig, 1, true) === nothing
        end
        let msig = "foo(x, ::Nothing)"
            @test JETLS.make_insert_text(msig, 0, true) == "\${1:x}, \${2:::Nothing}"
            @test JETLS.make_insert_text(msig, 1, true) == "\${1:::Nothing}"
            @test JETLS.make_insert_text(msig, 2, true) === nothing
        end
    end

    @testset "use_snippet=false" begin
        let msig = "sin(x::Number)"
            @test JETLS.make_insert_text(msig, 0, false) == "x::Number"
        end
        let msig = "filter(f, itr)"
            @test JETLS.make_insert_text(msig, 0, false) == "f, itr"
            @test JETLS.make_insert_text(msig, 1, false) == "itr"
        end
    end
end

get_newText(item::CompletionItem) =
    (@something item.textEdit return nothing).newText

@testset "method signature completion" begin
    let text = """
        sin(│
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "(")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test count(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    !isnothing(get_newText(item)) &&
                    occursin("sin", item.label)
            end == length(methods(sin))
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Type-based filtering
    let text = """
        sin(42,│
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ",")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test count(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    !isnothing(get_newText(item)) &&
                    occursin("sin", item.label)
            end == 1
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """let x = 42
            sin(x,│
        end"""
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ",")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test count(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    !isnothing(get_newText(item)) &&
                    occursin("sin", item.label)
            end == 1
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Local-binding type (`x :: String` from `let x = "a"`) and literal arg type
    # (`Const(1)`) jointly narrow `baz` to its unique 2-arg overload. Needs full
    # analysis to load `baz`'s methods, so route through `with_completion_request`.
    let text = """
        baz(::Int, ::String) = 1
        baz(::Int, ::Int) = 2
        baz(::String, ::String) = 3
        baz(::String, ::Int) = 4
        let x = "a"
            baz(1, x,│
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ",")
        cnt = Ref(0)
        with_completion_request(text; context) do _, result, _
            items = result.items
            @test count(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    !isnothing(get_newText(item)) &&
                    occursin("baz", item.label)
            end == 1
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        filter(isodd,│
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ",")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test all(items) do item
                newText = get_newText(item)
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    !isnothing(newText) &&
                    (newText == "" || startswith(newText, " ")) # Allow `newText == ""` for `filter(f)` case
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        filter(isodd, │
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = " ")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test all(items) do item
                newText = get_newText(item)
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    !isnothing(newText) &&
                    (newText == "" || !startswith(newText, " ")) # Allow `newText == ""` for `filter(f)` case
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end


    # Test case where all positional args are filled (textEdit.newText should be empty)
    let text = """
        println(stdout, │
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = " ")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            method_items = filter(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method"
            end
            # Should include methods where args are already filled (empty newText)
            @test any(item -> get_newText(item) == "", method_items)
            # Should also include methods with remaining args
            @test any(item -> !isempty(something(get_newText(item), "")), method_items)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Test case where all args are filled - newText should be empty
    let text = """
        sin(x, │
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ",")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            @test all(items) do item
                newText = get_newText(item)
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "method" &&
                    newText == ""
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    let text = """
        console.log(│
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "(")
        cnt = Ref(0)
        with_completion_items(text; context) do _
            cnt[] = 1
        end
        @test cnt[] == 1
    end

    @testset "Tolerate invalid calls with `Union{}`-inferred call argument types" begin
        text = """
        sin(throw(),│)
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ",")
        cnt = Ref(0)
        with_completion_items(text; context) do _
            cnt[] = 1
        end
        @test cnt[] == 1
    end
end

# keyword argument completion
# ===========================

@testset "keyword argument completion" begin
    let text = """
        printstyled(; │
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = ";")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            keyword_items = filter(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "keyword argument"
            end
            @test !isempty(keyword_items)
            @test any(item -> item.label == "bold", keyword_items)
            @test any(item -> item.label == "color", keyword_items)
            @test all(keyword_items) do item
                item.insertText !== nothing && endswith(item.insertText, " = ")
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Test keyword name completion excludes already-specified keywords
    let text = """
        printstyled(; bold=true, │
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = " ")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            keyword_items = filter(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "keyword argument"
            end
            @test !isempty(keyword_items)
            @test !any(item -> item.label == "bold", keyword_items)
            @test any(item -> item.label == "color", keyword_items)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Test no keyword completion after `=`
    let text = """
        printstyled(; bold=│
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = "=")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            keyword_items = filter(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "keyword argument"
            end
            @test isempty(keyword_items)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Don't insert `=` if the same local variable exists in the scope
    let text = """
        let bold = false
            printstyled(; │
        end
        """
        context = CompletionContext(;
            triggerKind = CompletionTriggerKind.TriggerCharacter,
            triggerCharacter = " ")
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            keyword_items = filter(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "keyword argument"
            end
            @test !isempty(keyword_items)
            @test any(item -> item.label == "bold" && item.insertText == "bold", keyword_items)
            @test any(item -> item.label == "color" && item.insertText == "color = ", keyword_items)
            cnt[] += 1
        end
        @test cnt[] == 1
    end

    # Test no `=` insertion when cursor is before existing `=`
    let text = """
        printstyled(; bol│=true)
        """
        context = CompletionContext(; triggerKind = CompletionTriggerKind.Invoked)
        cnt = Ref(0)
        with_completion_items(text; context) do (; result)
            items = result.items
            keyword_items = filter(items) do item
                item.labelDetails !== nothing &&
                    item.labelDetails.description == "keyword argument"
            end
            @test all(keyword_items) do item
                !occursin("=", something(item.insertText, ""))
            end
            cnt[] += 1
        end
        @test cnt[] == 1
    end
end

@testset "should_insert_spaces_around_equal" begin
    function test_should_insert_spaces(text::AbstractString)
        clean_text, positions = JETLS.get_text_and_positions(text)
        fi = JETLS.FileInfo(0, clean_text, "test.jl")
        st0 = JETLS.build_syntax_tree(fi)
        b = JETLS.xy_to_offset(fi, positions[1])
        call = JETLS.cursor_call(fi.parsed_stream, st0, b)
        ca = JETLS.CallArgs(call, b)
        return JETLS.should_insert_spaces_around_equal(fi, ca)
    end
    @test test_should_insert_spaces("func(; │)")
    @test !test_should_insert_spaces("func(; a=1, │)")
    @test !test_should_insert_spaces("func(; a=1, b=2, │)")
    @test test_should_insert_spaces("func(; a = 1, │)")
    @test test_should_insert_spaces("func(; a = 1, b = 2, │)")
    @test test_should_insert_spaces("func(; a = 1, b = 2, c=3, │)")
    @test !test_should_insert_spaces("func(; a=1, b=2, c = 3, │)")
    @test test_should_insert_spaces("func(; a = 1, b=2, │)")
end

@testset "cursor_equals_position" begin
    function test_cursor_equals_position(text::AbstractString)
        clean_text, positions = JETLS.get_text_and_positions(text)
        fi = JETLS.FileInfo(0, clean_text, "test.jl")
        st0 = JETLS.build_syntax_tree(fi)
        b = JETLS.xy_to_offset(fi, positions[1])
        call = JETLS.cursor_call(fi.parsed_stream, st0, b)
        ca = JETLS.CallArgs(call, b)
        return JETLS.cursor_equals_position(ca, b)
    end

    # cursor after `=` in keyword argument → true
    @test test_cursor_equals_position("func(; a=│)") === true
    @test test_cursor_equals_position("func(; a=│1)") === true
    @test test_cursor_equals_position("func(; a=1│)") === true
    @test test_cursor_equals_position("func(; a = │)") === true
    @test test_cursor_equals_position("func(; a = │1)") === true
    @test test_cursor_equals_position("func(; a = 1│)") === true
    @test test_cursor_equals_position("func(; a=1, b=│)") === true
    @test test_cursor_equals_position("func(; a=1, b=│2)") === true
    @test test_cursor_equals_position("func(a=│)") === true
    @test test_cursor_equals_position("func(a=│1)") === true
    @test test_cursor_equals_position("func(a=1│)") === true
    @test test_cursor_equals_position("func(; a=│") === true  # incomplete
    @test test_cursor_equals_position("func(; a=│1") === true  # incomplete
    @test test_cursor_equals_position("func(; a=1│") === true  # incomplete
    @test test_cursor_equals_position("func(; a = │") === true  # incomplete
    @test test_cursor_equals_position("func(; a = │1") === true  # incomplete
    @test test_cursor_equals_position("func(; a = 1│") === true  # incomplete
    @test test_cursor_equals_position("func(; a=1, b=│") === true  # incomplete
    @test test_cursor_equals_position("func(; a=1, b=│2") === true  # incomplete
    @test test_cursor_equals_position("func(a=│") === true  # incomplete
    @test test_cursor_equals_position("func(a=│1") === true  # incomplete
    @test test_cursor_equals_position("func(a=1│") === true  # incomplete

    # cursor before `=` sign in kw arg → false (has `=`, don't insert)
    @test test_cursor_equals_position("func(; a│=1)") === false
    @test test_cursor_equals_position("func(; a=1, b│=2)") === false
    @test test_cursor_equals_position("func(a│=1)") === false
    @test test_cursor_equals_position("func(; │a=1)") === false
    @test test_cursor_equals_position("func(│a=1)") === false
    @test test_cursor_equals_position("func(; a=1, │b=2)") === false
    @test test_cursor_equals_position("func(; a│=1") === false  # incomplete
    @test test_cursor_equals_position("func(; a=1, b│=2") === false  # incomplete
    @test test_cursor_equals_position("func(a│=1") === false  # incomplete
    @test test_cursor_equals_position("func(; │a=1") === false  # incomplete
    @test test_cursor_equals_position("func(│a=1") === false  # incomplete
    @test test_cursor_equals_position("func(; a=1, │b=2") === false  # incomplete

    # cursor not in any kw arg → nothing (no `=`, insert it)
    @test test_cursor_equals_position("func(; │)") === nothing
    @test test_cursor_equals_position("func(; a=1, │)") === nothing
    @test test_cursor_equals_position("func(; │") === nothing  # incomplete
    @test test_cursor_equals_position("func(; a=1, │") === nothing  # incomplete
end

module soft_scope_completions_module
    global x = 1
end

@testset "soft scope completions" begin
    # Place the cursor at a use site (println(x)) so `is_relevant` doesn't
    # filter out `x`.
    let marked_text = """
        for _ = 1:10
            x = 2
            println(│x)
        end
        """
        # Without soft_scope: `x` is a new local (ambiguous local)
        cbs_hard = get_cursor_bindings(marked_text;
            context_module=soft_scope_completions_module, soft_scope=false)
        xs_hard = filter(((bi, _, _),) -> bi.name == "x", cbs_hard)
        @test length(xs_hard) == 1
        @test xs_hard[1][1].kind === :local

        # With soft_scope: `x` assigns to the existing global
        cbs_soft = get_cursor_bindings(marked_text;
            context_module=soft_scope_completions_module, soft_scope=true)
        xs_soft = filter(((bi, _, _),) -> bi.name == "x", cbs_soft)
        @test length(xs_soft) == 1
        @test xs_soft[1][1].kind === :global
    end
end

function make_completion_request(id::Int, uri::URI, pos::Position)
    return CompletionRequest(;
        id,
        params = CompletionParams(;
            textDocument = TextDocumentIdentifier(; uri),
            position = pos))
end

@testset "completion snapshot ordering" begin
    @testset "prior and later didChange" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            initial = "let initial_only = 1\n    ini\nend"
            captured = "let captured_only = 2\n    cap\nend"
            later = "let later_only = 3\n    lat\nend"
            JETLS.cache_file_info!(server, uri, 1, initial)
            pos = Position(; line = 1, character = 7)
            request = make_completion_request(1, uri, pos)
            next_request = make_completion_request(2, uri, pos)
            @test JETLS.is_sequential_msg(request)
            prepared = queued_snapshot_requests(server, [
                make_DidChangeTextDocumentNotification(uri, captured, 2), request,
                make_DidChangeTextDocumentNotification(uri, later, 3), next_request])
            @test length(prepared) == 2
            @test prepared[1].msg === request
            @test prepared[1].snapshot.fi.version == 2
            @test prepared[1].msg.params.position == pos
            @test JETLS.adjust_position(prepared[1].snapshot, uri, prepared[1].msg.params.position) == pos
            @test prepared[1].snapshot.cache_uri == uri
            @test prepared[1].snapshot.notebook === nothing
            @test prepared[2].snapshot.fi.version == 3
            @test JETLS.get_file_info(server.state, uri) === prepared[2].snapshot.fi
            @test prepared[1].snapshot.fi !== prepared[2].snapshot.fi

            response = dispatch_snapshot_request(server, recorder, prepared[1])
            @test response isa CompletionResponse
            @test response.error === nothing
            cv_has(response.result.items, ["captured_only"]; kind = :local)
            cv_nhas(response.result.items, ["initial_only", "later_only"])
            response = dispatch_snapshot_request(server, recorder, prepared[2])
            @test response.error === nothing
            cv_has(response.result.items, ["later_only"]; kind = :local)
            cv_nhas(response.result.items, ["initial_only", "captured_only"])
        end
    end

    @testset "macro trigger uses captured text" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, "\n")
            pos = Position(; line = 0, character = 1)
            request = CompletionRequest(;
                id = 1,
                params = CompletionParams(;
                    textDocument = TextDocumentIdentifier(; uri),
                    position = pos,
                    context = CompletionContext(;
                        triggerKind = CompletionTriggerKind.TriggerCharacter,
                        triggerCharacter = "@")))
            prepared = only(queued_snapshot_requests(server, [
                make_DidChangeTextDocumentNotification(uri, "@", 2), request,
                make_DidChangeTextDocumentNotification(uri, "x", 3)]))
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response.error === nothing
            @test !response.result.isIncomplete
            cv_has(response.result.items, ["@time"])
            cv_nhas(response.result.items, ["sin"])
            item = only(filter(item -> item.label == "@time", response.result.items))
            @test item.textEdit isa TextEdit
            @test item.textEdit.range == Range(; start = Position(; line = 0, character = 0), var"end" = pos)
        end
    end

    @testset "cancellation before prepared dispatch" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, "\\alpha")
            request = make_completion_request(1, uri, Position(; line = 0, character = 6))
            prepared = only(queued_snapshot_requests(server, [request]))
            @test prepared.snapshot !== nothing
            JETLS.handler_concurrent_message(server, CancelRequestNotification(; params = CancelParams(; id = request.id)))
            @test JETLS.is_cancelled(server.state.currently_handled[request.id])
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response.result === nothing
            @test response.error isa ResponseError
            @test response.error.code == ErrorCodes.RequestCancelled
        end
    end

    @testset "missing cache is not retried" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            request = make_completion_request(1, uri, Position(; line = 0, character = 6))
            prepared = only(queued_snapshot_requests(server, [request]))
            @test prepared.snapshot === nothing
            @test JETLS.get_file_info(server.state, uri) === nothing
            JETLS.cache_file_info!(server, uri, 1, "\\alpha")
            @test JETLS.snapshot_request_message(server.state, request, uri).snapshot !== nothing
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa ResponseMessage
            @test response.error === nothing
            @test response.result === null
        end
    end

    @testset "notebook $change_kind" for change_kind in (:preceding_lines, :remove_preceding, :remove_requested)
        with_manual_dispatch_server() do server, recorder
            state = server.state
            notebook_uri = URI("file:///completion-snapshot.ipynb")
            cell1 = URI("vscode-notebook-cell:/completion-snapshot.ipynb#1")
            cell2 = URI("vscode-notebook-cell:/completion-snapshot.ipynb#2")
            text, positions = JETLS.get_text_and_positions("""
                for _ in 1:1
                    x = 2
                    println(│x)
                end
                \\alpha│""")
            cells = JETLS.NotebookCellInfo[
                JETLS.NotebookCellInfo(cell1, NotebookCellKind.Code, 1, "prefix = 1\nprefix"),
                JETLS.NotebookCellInfo(cell2, NotebookCellKind.Code, 1, text)]
            concat = JETLS.concatenate_cells(cells)
            notebook = JETLS.NotebookInfo(1, "jupyter-notebook", state.encoding, cells, concat)
            JETLS.store!(state.notebook_cache) do cache
                Base.PersistentDict(cache, notebook_uri => notebook), nothing
            end
            JETLS.store!(state.cell_to_notebook) do cache
                for cell in cells
                    cache = Base.PersistentDict(cache, cell.uri => notebook_uri)
                end
                cache, nothing
            end
            fi = JETLS.cache_notebook_file_info!(server, notebook_uri, notebook)
            change = if change_kind === :preceding_lines
                NotebookDocumentChangeEventCells(;
                    textContent = [NotebookDocumentChangeEventCellsTextContentItem(;
                        document = VersionedTextDocumentIdentifier(; uri = cell1, version = 2),
                        changes = [TextDocumentContentChangeEvent(; text = "prefix = 1")])])
            else
                removed_uri = change_kind === :remove_preceding ? cell1 : cell2
                NotebookDocumentChangeEventCells(;
                    structure = NotebookDocumentChangeEventCellsStructure(;
                        array = NotebookCellArrayChange(;
                            start = UInt(change_kind === :remove_preceding ? 0 : 1),
                            deleteCount = UInt(1)),
                        didClose = [TextDocumentIdentifier(; uri = removed_uri)]))
            end
            prepared = queued_snapshot_requests(server, [
                make_completion_request(1, cell2, positions[1]),
                make_completion_request(2, cell2, positions[2]),
                DidChangeNotebookDocumentNotification(;
                    params = DidChangeNotebookDocumentParams(;
                        notebookDocument = VersionedNotebookDocumentIdentifier(;
                            uri = notebook_uri, version = 2),
                        change = NotebookDocumentChangeEvent(; cells = change)))])
            @test length(prepared) == 2
            @test JETLS.get_file_info(state, notebook_uri).version == 2
            for (i, request) in enumerate(prepared)
                snapshot = request.snapshot
                @test snapshot.fi === fi
                @test snapshot.fi.version == 1
                @test snapshot.cache_uri == notebook_uri
                @test snapshot.notebook === concat
                pos = request.msg.params.position
                @test pos == positions[i]
                @test JETLS.adjust_position(snapshot, cell2, pos) ==
                    Position(; line = positions[i].line + 2, character = positions[i].character)
            end
            if change_kind === :remove_requested
                @test !JETLS.is_notebook_cell_uri(state, cell2)
            else
                current = JETLS.snapshot_request_message(state, prepared[2].msg, cell2)
                pos = prepared[2].msg.params.position
                @test JETLS.adjust_position(current.snapshot, cell2, pos) !=
                    JETLS.adjust_position(prepared[2].snapshot, cell2, pos)
            end

            pos = JETLS.adjust_position(prepared[1].snapshot, cell2, prepared[1].msg.params.position)
            items, _ = JETLS.get_completion_items(
                state, cell2, prepared[1].snapshot, pos, nothing;
                context_module = soft_scope_completions_module)
            cv_has(items, ["x"]; kind = :global)
            response = dispatch_snapshot_request(server, recorder, prepared[2])
            @test response.error === nothing
            item = only(filter(item -> item.label == "\\alpha", response.result.items))
            @test item.textEdit isa TextEdit
            @test item.textEdit.newText == "α"
            @test item.textEdit.range == Range(;
                start = Position(; line = 4, character = 0),
                var"end" = Position(; line = 4, character = 6))
        end
    end

    @testset "request/response routing sanity" begin
        withserver() do (; server, writemsg, writereadmsg, id_counter)
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, "let initial_only = 1\n    ini\nend")
            writemsg(make_DidChangeTextDocumentNotification(
                uri, "let captured_only = 2\n    cap\nend", 2))
            id = id_counter[] += 1
            pos = Position(; line = 1, character = 7)
            (; raw_res) = writereadmsg(make_completion_request(id, uri, pos))
            @test raw_res isa CompletionResponse
            @test raw_res.error === nothing
            cv_has(raw_res.result.items, ["captured_only"]; kind = :local)
            cv_nhas(raw_res.result.items, ["initial_only"])
        end
    end
end

end # module test_completions
