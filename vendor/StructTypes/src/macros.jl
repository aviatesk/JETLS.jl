isolate_name(name) = split(string(name), '.')[end]

for struct_type in (:Struct, :Mutable, :CustomStruct, :OrderedStruct, :AbstractType, :DictType, :ArrayType, :StringType, :NumberType, :BoolType, :NullType)
    @eval begin
        """
            @$(isolate_name($struct_type))(expr::Expr)
            @$(isolate_name($struct_type))(expr::Symbol)
        
        If `expr` is a struct definition, sets the `StructType` of the defined struct to
        `$(isolate_name($struct_type))()`. If `expr` is the name of a `Type`, sets the `StructType` of that
        type to `$(isolate_name($struct_type))()`.

        # Examples
        ```julia
        @$(isolate_name($struct_type)) MyStruct
        ```
        is equivalent to
        ```julia
        StructTypes.StructType(::Type{MyStruct}) = StructType.Struct()
        ```
        and 
        ```julia
        @$(isolate_name($struct_type)) struct MyStruct
            val::Int
        end
        ```
        is equivalent to
        ```julia
        struct MyStruct
            val::Int
        end
        StructTypes.StructType(::Type{MyStruct}) = StructType.Struct()
        ```
        """ macro $struct_type(expr)
            return macro_constructor(expr, $struct_type)
        end
    end
end

function macro_constructor(expr::Expr, structtype)
    if expr.head == :struct
        return esc(quote
            $expr
            StructTypes.StructType(::Type{$(expr.args[2])}) = $structtype()
        end)
    else
        return :(throw(ArgumentError("StructType macros can only be used with a struct definition or a Type")))
    end
end
function macro_constructor(expr::Symbol, structtype)
    return esc(quote
        if $(expr) isa Type
            StructTypes.StructType(::Type{$(expr)}) = $structtype()
        else
            throw(ArgumentError("StructType macros can only be used with a struct definition or a Type"))
        end
    end)
end

"""
Macro to add subtypes for an abstract type without the need for type field.
For a given `abstract_type`` and `struct_subtype` generates custom lowered NameTuple 
with all subtype fields and additional `StructTypes.subtypekey` field
used for identifying the appropriate concrete subtype.

usage:
```julia
abstract type Vehicle end
struct Car <: Vehicle
    make::String
end
StructTypes.subtypekey(::Type{Vehicle}) = :type
StructTypes.subtypes(::Type{Vehicle}) = (car=Car, truck=Truck)
StructTypes.@register_struct_subtype Vehicle Car
```
"""
macro register_struct_subtype(abstract_type, struct_subtype)
    AT = Core.eval(__module__, abstract_type)
    T = Core.eval(__module__, struct_subtype)
    field_name = StructTypes.subtypekey(AT)
    field_value = findfirst(x->x === T, StructTypes.subtypes(AT))
    x_names = [:(x.$(e)) for e in fieldnames(T)] # x.a, x.b, ...
    name_types = [:($n::$(esc(t))) for (n, t) in zip(fieldnames(T), fieldtypes(T))] # a::Int, b::String, ...
    quote
        StructTypes.StructType(::Type{$(esc(struct_subtype))}) = StructTypes.CustomStruct()
        StructTypes.lower(x::$(esc(struct_subtype))) = ($(esc(field_name)) = $(QuoteNode(field_value)), $(x_names...))
        StructTypes.lowertype(::Type{$(esc(struct_subtype))}) = @NamedTuple{$field_name::$(esc(Symbol)), $(name_types...)}
        $(esc(struct_subtype))(x::@NamedTuple{$field_name::$(esc(Symbol)), $(name_types...)}) = $(esc(struct_subtype))($(x_names...))
    end
end