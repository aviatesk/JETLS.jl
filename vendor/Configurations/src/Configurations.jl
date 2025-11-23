module Configurations

using TOML
using ExproniconLite
using OrderedCollections

export @option,
    @type_alias,
    # main interface
    from_dict,
    from_kwargs,
    from_toml,
    to_dict,
    to_toml,
    # builtin types
    no_default,
    Maybe,
    Reflect,
    OptionField,
    # reflection
    field_default,
    # field_alias,
    type_alias,
    # traits
    is_option,
    # parse
    from_dict,
    from_kwargs,
    from_toml,
    from_toml_if_exists,
    # serialize
    to_dict,
    DuplicatedFieldError,
    DuplicatedAliasError,
    InvalidKeyError,
    FieldTypeConversionError,
    TOMLStyle,
    YAMLStyle,
    JSONStyle

include("compat.jl")
include("errors.jl")
include("types.jl")
include("convert.jl")
include("reflection.jl")
include("utils.jl")
include("codegen.jl")

include("from_dict.jl")
include("from_kwargs.jl")
include("from_toml.jl")
# include("parse.jl")
include("serialize.jl")

end
