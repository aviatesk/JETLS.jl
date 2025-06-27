using JETLS: JS, JL

function parsedstream(s::AbstractString, rule::Symbol=:all)
    stream = JS.ParseStream(s)
    JS.parse!(stream; rule)
    return stream
end

function jsparse(s::AbstractString)
    JS.build_tree(JS.SyntaxNode, parsedstream(s); filename=@__FILE__)
end

function jlparse(s::AbstractString)
    JS.build_tree(JL.SyntaxTree, parsedstream(s); filename=@__FILE__)
end
