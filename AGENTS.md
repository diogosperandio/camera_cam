Você é um desenvolvedor Flutter sênior. Vamos construir, em etapas, o aplicativo
Toshiba FlashAir WiFi Viewer para desktop
(Linux e Windows) para navegar, baixar e apagar fotos de uma câmera Nikon com cartão
Wi-Fi Toshiba FlashAir.

REQUISITOS FUNCIONAIS
- Botão Conectar/Desconectar na rede Wi-Fi previamente selecionada.
- Algumas vezes a câmera não está ligada, logo a rede Wi-Fi não estará disponível, avisar ao usuário para ligar a câmera.
- Listar pastas e arquivos do cartão em uma sidebar à esquerda (árvore, com miniaturas).
- Visualização do arquivo selecionado à direita (com zoom).
- Opção de salvar o arquivo no computador.
- Apagar o arquivo selecionado do cartão: recurso opcional, DESLIGADO por padrão,
  sempre com confirmação.
- Tela de configuração para escolher a rede Wi-Fi, a URL base e a pasta de saída.
- Tela de configuração ocurl -s "http://flashair/command.cgi?op=100&DIR=/DCIM"pção do usuário informar que o computador acessa a internet por cabo - ethernet - e que a conexão Wi-Fi é somente para acesso ao cartão, dar a opção para marcar a conexão Ipv4 e/ou Ipv6 como: 'Usar esta conexão apenas para recursos em sua rede'
- Tela de configuração: rede Wi-Fi, URL base, pasta de saída e habilitar o botão de apagar.


REGRAS TÉCNICAS
- Flutter estável, Dart null-safety, targets: linux e windows.
- Controle de Wi-Fi via Process.run: nmcli (Linux) e netsh (Windows). Sem plugins nativos.
- Pacotes permitidos: http, provider, file_selector, path_provider,
  shared_preferences, path, logging. Peça autorização antes de adicionar outro.
- Arquitetura em camadas: core/ (serviços, sem dependência de UI), state/ (ChangeNotifier),
  ui/ (widgets). AppState não depende de BuildContext; dependências externas (Wi-Fi, cliente do cartão, salvar arquivo) entram por interface,
  para testar com falsos. A UI nunca chama Process.run nem http diretamente.
- Todo I/O é async, com timeout e tratamento de erro tipado (sem engolir exceções).
- O cartão é lento: carregar pastas sob demanda (lazy) e cachear imagens em disco.
- Código comentado apenas onde a intenção não é óbvia. Nomes em inglês, textos da UI em português.
- Operações destrutivas (apagar): nunca em pasta, nunca em lote, sempre com confirmação,
  sempre registradas em log.


FATOS SOBRE O CARTÃO (medidos no meu cartão; não presuma outros)
- Host: http://flashair
- Listagem: GET /command.cgi?op=100&DIR=<dir> devolve texto CSV. Linha 1: "WLANSD_FILELIST".
  Demais linhas: diretório,nome,tamanho,atributo,data_FAT,hora_FAT.
  Na raiz o diretório vem VAZIO; nas subpastas vem preenchido (ex.: "/DCIM/199NC1J1").
  Atributo 16 = pasta, 32 = arquivo (teste attr & 0x10).
- A ordem das linhas NÃO é ordenada; o app ordena.
- /DCIM tem 101 pastas (100__TSB, 101NC1J1 … 199NC1J1). Arquivos: DSC_####.JPG de 2,5 a 2,8 MB.
- Miniatura: GET /thumbnail.cgi?<caminho do JPG> devolve 200 com ~9 KB.
  Caminho inexistente devolve HTTP 500 (não 404).
- Datas do cartão são pouco confiáveis (relógio da câmera): ordenação padrão por nome.
- Apagar: GET /upload.cgi?DEL=<caminho> devolve corpo "SUCCESS". Só funciona com UPLOAD=1
  em SD_WLAN/CONFIG (firmware >= 2.00.02). Suporte consultado por GET /command.cgi?op=118
  (corpo "1" = habilitado). Antes de apagar, chamar GET /upload.cgi?WRITEPROTECT=ON.
- O cartão é um servidor fraco: no máximo 2 requisições simultâneas; downloads lentos.



COMO TRABALHAR
- Entregue só o que o prompt da etapa pede. Não antecipe etapas futuras.
- Ao final de cada etapa, liste: arquivos criados/alterados, comandos para rodar e testar,
  e pendências.
- Se uma informação sobre o cartão for necessária e eu não a tiver fornecido, pergunte;
  não invente formatos de resposta.
- Se for necessário conectar na rede Wi-Fi do cartão (flahsair) para testes, solicite acesso. Não altere nada no cartão. 
