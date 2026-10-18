# Importação de conexão individual

O botão **Importar conexão…** recebe um arquivo JSON local com `base_url`, `principal_id` e `token`. O leitor abre um arquivo regular, rejeita symlink final/FIFO/URL remota e limita a leitura a 64 KiB. Erros de leitura e decode não exibem conteúdo nem caminho do arquivo. O token não é preenchido no campo publicado da interface, exportado ou enviado em argumentos de processo.

O arquivo informa a identidade esperada, não concede acesso. Antes de trocar a conexão, o Desk valida a política de URL, autentica no servidor, consulta `/me` e o registry autorizado e compara o principal autenticado com `principal_id`. O fluxo manual também valida o candidato antes de salvar a credencial. Rótulos de projetos e nomes de usuários não concedem permissões.

A conexão atual permanece utilizável durante a validação ou se ela falhar. Antes de gravar o token nas Chaves, o Desk valida o registry, lê a seleção do namespace de destino e salva o rascunho atual. A troca efetiva ocorre no MainActor, sem uma suspensão entre a gravação da credencial e a instalação do registry já validado. Falhas ao carregar rascunhos existentes preservam seus arquivos e bloqueiam sua sobrescrita, conforme a política do cache local.

Fechar a janela cancela a validação e invalida sua geração. Uma resposta tardia não pode ativar a conexão. UserDefaults guarda somente endpoint, opt-in e principal autenticado; a credencial fica no Keychain. O principal guardado é verificado no reconectar. Falha de autenticação, mudança inesperada de principal ou endpoint inválido não promove a conexão MCP global.

Os testes de ativação usam serviços e credenciais sintéticos e verificam autenticação antes de gravação, identidade divergente, falha nas Chaves, seleção corrompida, cancelamento com resposta tardia e mudança de principal no reconectar. Os testes do leitor cobrem limites de tamanho, JSON inválido, campos ausentes e tipos de arquivo inadequados.

## Dados reais

A API sintética local continua restrita ao perfil de verificação. A ativação habitual exige um handoff do backend com endpoint estável, arquivo privado da credencial individual, principal/registry esperados e prova da importação e dos acessos. A política Henrique/Emílio é aplicada pelo servidor; o cliente não deduz ownership ou grants do conteúdo legado. Validar o cliente não demonstra a migração de dados nem o bloqueio das antigas rotas globais.

Metadados opcionais `name`, `snapshotIsCurrentProduction` e `requiresMacActive` identificam o perfil localmente. Depois da autenticação, o Desk guarda e exibe um aviso persistente com o nome, condição de snapshot de revisão e dependência deste Mac para inferência. Esses metadados não concedem permissões nem habilitam providers; isso continua sendo responsabilidade das capabilities e do registry do servidor. Identificações longas, caracteres de controle e inclusão da própria credencial no nome são rejeitados. Configuração manual limpa o aviso anterior; perfis antigos sem metadados mantêm o comportamento anterior.
