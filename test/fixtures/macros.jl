macro m_inner_error(x)
    error("Error in foo")
end

macro m_outer_error(x)
    :(@m_inner_error( $x ), @m_inner_error( $nothing ))
end
