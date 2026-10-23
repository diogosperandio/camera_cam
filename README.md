# Toshiba FlashAir WiFi Viewer

Aplicativo desktop para Linux e Windows que navega, visualiza, salva e gerencia
fotos de uma câmera com cartão Wi-Fi Toshiba FlashAir.

## Funcionalidades

- Conecta e desconecta o computador da rede Wi-Fi do cartão FlashAir.
- Navega pelas pastas e fotos do cartão em uma árvore com miniaturas.
- Visualiza as fotos em tamanho ampliado, com controles de zoom e ajuste à tela.
- Salva a foto selecionada em uma pasta do computador.
- Permite configurar a rede Wi-Fi, a URL do cartão e a pasta de destino.
- Pode apagar fotos e pastas vazias, quando o recurso estiver habilitado, sempre
  mediante confirmação.
- Verifica atualizações do aplicativo e orienta a instalação de novas versões.
- Oferece configuração para manter o acesso à internet por Ethernet enquanto o
  Wi-Fi é usado apenas para comunicação com o cartão.

## Capturas de tela

### Conexão com o cartão

![Conexão com a rede Wi-Fi do cartão FlashAir](assets/Screenshot%20from%202026-10-22%2009-34-40.png)

### Navegação pelas pastas

![Árvore de pastas do cartão FlashAir](assets/Screenshot%20from%202026-10-22%2009-35-03.png)

### Visualização da foto

![Visualização, download e exclusão de uma foto](assets/Screenshot%20from%202026-10-22%2009-35-09.png)

## Apagar pastas vazias

A exclusão precisa estar habilitada nas Configurações do aplicativo e o cartão
FlashAir deve estar configurado com `UPLOAD=1` em `SD_WLAN/CONFIG`. O aplicativo
apaga somente pastas confirmadas como vazias imediatamente antes da operação;
as pastas `/` e `/DCIM` nunca são removidas.

Antes de confirmar, confira as pastas selecionadas. A exclusão é irreversível e,
se a câmera não reconhecer o cartão depois da operação, desligue-a e ligue-a
novamente.

O que fazer: Coloque o cartão no computador, acesse o cartão e procure pela pasta SD_WLAN (está oculta). Entre nesta pasta e edite o arquivo CONFIG, acrescentando a linha `UPLOAD=1`

## Script Release.sh

Executar: release.sh


O que ele faz:
Confere o repositório. Verifica se a árvore está limpa (arquivos rastreados), avisa se você não está em main ou master, e recusa se sua branch estiver atrás do GitHub.
Mostra a última versão. Exibe a última tag, a última release publicada (se o gh estiver instalado e autenticado), a versão do pubspec.yaml e avisa se há release em rascunho, que indica build em andamento ou que falhou.
Pergunta a nova versão. O campo já vem preenchido com a última versão +1 no patch (v1.0.1 sugere 1.0.2), editável no teclado. Aceita com ou sem o v, recusa formato inválido ou tag que já existe, e avisa se a versão for menor que a última.
Mostra o resumo e pede confirmação. O padrão é “não”, então só s continua.
Roda flutter analyze e flutter test antes de alterar qualquer coisa. Se falhar, nada é modificado.
Atualiza o pubspec.yaml para X.Y.Z+N, incrementando também o número de build. Depois faz o commit, cria a tag anotada e envia a branch e a tag com um único git push.
Oferece acompanhar o build com gh run watch e mostra os links de Actions e Releases.
Sobre “compilar”

O script não compila localmente. Quem compila para Linux e Windows é o GitHub Actions, e o envio da tag é o que dispara o workflow. Para também compilar no seu computador antes de lançar, acrescente flutter build linux --release na etapa de verificações do script.

Pontos de atenção
Uma versão “pula” quando você muda o commit. O script faz um commit só do pubspec.yaml, então qualquer outra alteração precisa estar commitada antes, ou ele recusa.
Dependências. O read -e -i exige bash 4 ou superior, o que o Linux já tem. No Windows, rode pelo Git Bash ou WSL. O sed -i é o do GNU, não funciona igual no macOS.
O nome do workflow precisa ser release.yml, como no que passei antes, para o acompanhamento do build achar a execução.
Se o push falhar, o script imprime o comando para tentar de novo e o comando para desfazer o commit e a tag locais.
