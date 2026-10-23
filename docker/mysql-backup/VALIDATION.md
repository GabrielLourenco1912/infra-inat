# Validação executada em 22/10/2026

## Implementado

Serviço `mysql-backup` no Compose padrão, Dockerfile com apenas os clientes
MySQL, script de backup/restauração, cron diário às 02h15 locais, configuração
no mesmo `.env` da aplicação e armazenamento por bind mount. Não há arquivos
`.conf`/`.cnf` nem mount de configuração separado. Instalação e operação estão
descritas em [README.md](README.md). O CI/CD testa a integração, publica a
imagem `ghcr.io/gabriellourenco1912/inat-mysql-backup` junto de backend/frontend
e inclui as três imagens por commit no release de deploy. O deploy valida as
variáveis do `.env` e inicia o cron usando a imagem publicada.

## Testado

Comando executado com sucesso, código de saída **0**:

```bash
bash docker/mysql-backup/tests/integration.sh
```

O teste criou um MySQL 8.0 descartável, sem portas publicadas e com dados em
tmpfs. Utilizou um `.env` temporário com modo `0600`, credenciais aleatórias e
diretórios temporários próprios, sem
ler o `.env` da aplicação nem montar `db_data`.

Resultados confirmados:

- Serviço e imagem GHCR incluídos no Compose padrão, sem profile, e comando
  `check` validado antes de iniciar o MySQL, sem acessar o banco.
- Valores padrão do Compose conferidos: banco, usuário e senha do backup
  reutilizam `DB_NAME`, `DB_USERNAME` e `DB_PASSWORD` da aplicação.
- Senha do backup com espaços, `$`, aspas, crases e barra invertida aceita pelo
  cliente, sem usar arquivo adicional ou senha na linha de comando.
- Configurações sem senha ou com porta inválida recusadas.
- Backup por conta dedicada, nome UTC, arquivo gzip e modos `0700`/`0600`.
- Restauração de tabelas, dados UTF-8, view, procedure, função e evento.
- Trigger restaurada executada por uma inserção real, com auditoria conferida;
  os dados do banco de origem permaneceram iguais.
- Retenção de 30 e 45 dias, recusa abaixo de 30 e ausência de exclusões após
  falha no dump; arquivos recentes e de outros bancos preservados.
- Bloqueio de backup/restauração concorrentes e liberação da trava após saída.
- Recusa dos bancos operacional, de sistema, inexistentes e não vazios,
  inclusive destinos com apenas rotina ou evento.
- Recusa de gzip corrompido, SQL selecionando a origem e event scheduler ativo.
- Importação com erro deixou destino parcial, registrou essa condição e impediu
  uma nova restauração nesse destino.
- Healthcheck do cron e execução real de um job recuperando as variáveis do
  ambiente original do container, com agenda de um minuto apenas no teste.
  A agenda de produção foi conferida como 02h15.
- Ausência da senha nos logs capturados e limpeza de temporários em sucesso e
  falha no mesmo container de agendamento.

Também passaram a validação do Compose com `.env.example`, `bash -n`, o parse do
YAML/Bash do workflow e `git diff --check`. O template real de release do CI foi
executado localmente com valores fictícios e mesclado ao Compose: as três
imagens ficaram fixadas por commit, o serviço de backup permaneceu ativo por
padrão e o bind de saída ficou configurado para criar o diretório do host.
A comprovação de recuperação veio da importação e das consultas no MySQL,
não apenas de `gzip -t`.

## Efetivamente ativado

**Nenhum agendamento de produção foi ativado nesta entrega.** O cron executado
foi exclusivamente o do teste descartável. Containers, rede, arquivos de teste
e credenciais temporárias foram removidos ao fim da suíte. A imagem final foi
construída localmente; não houve publicação em registry ou acesso a uma VPS.
O workflow está configurado para publicar no GHCR na próxima execução elegível
da branch `main`; essa execução do GitHub Actions não foi disparada aqui.

O deploy será realizado pelo responsável pelo ambiente, usando o pipeline e
o Compose. A configuração fica no próprio `.env`; a conta MySQL precisa ter os
grants descritos no guia. O bind mount cria o diretório de artefatos, e o
container aplica as permissões. Não é necessário fornecer acesso SSH nesta
sessão nem copiar scripts executáveis para o host. O armazenamento previsto é
`/var/backups/inat/mysql` no host. **Não há cópia externa configurada.** Nenhuma
restauração sobre dados reais ou mudança na conexão da aplicação foi realizada.
