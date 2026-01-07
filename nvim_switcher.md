* Source: https://gist.github.com/elijahmanor/b279553c0132bfad7eae23e34ceb593b
## Nvim swicher
* create Directory:
` mkdir ~/.config/nvims`
* put all new configs into  .configs/nvims/*
* add snippet to the zshhrc
* 
```sh
# >> ~/.zshrc
alias fd='fdfind'
alias nv='nvim'
alias nvs='nvim_switch_configuration'

nvim_switch_configuration () {
  config="$(
    fd -d 3 -L --min-depth 2 --regex "init\.(lua|vim)" -p "${XDG_CONFIG_HOME:-$HOME/.config}" \
    | awk -F"${XDG_CONFIG_HOME:-$HOME/.config}/" '{sub(/nvims\//, ""); sub(/nvim/, "default"); sub(/\/init.*/, ""); print $NF}' \
    | fzf --border --exit-0 --height=~50% --layout=reverse --prompt ' Neovim configuration switcher  ')"
  if [[ -z $config ]]; then
    printf "%s\n" "No configuration selected."
    return 0
  elif [[ $config == "default" ]]; then
    config=""
  else
    config="nvims/$config"
    alias nv="NVIM_APPNAME=$config nvim"
  fi
  NVIM_APPNAME=$config nvim "$@"
}
```
