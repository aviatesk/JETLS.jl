macro m_inner_error_JL(x)
    error("Error in foo")
end

macro m_outer_error_JL(x)
    :(@m_inner_error_JL( $x ), @m_inner_error_JL( $nothing ))
end
