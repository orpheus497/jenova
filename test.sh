_arg="test
"
_escaped=$(printf '%s\n' "$_arg" | sed "s/'/'\\\\''/g" && printf 'x')
echo "${_escaped%?x}"
