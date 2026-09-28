// Job auth-keygen: gera a chave RSA de assinatura do ms-auth uma unica vez
// (se o volume ja tem a chave, nao faz nada: tokens emitidos seguem validos).
import { generateKeyPairSync } from "node:crypto";
import { chownSync, existsSync, writeFileSync } from "node:fs";

const path = "/keys/signing-key.pem";
const AUTH_UID = 1001; // usuario nestjs da imagem do ms-auth

if (existsSync(path)) {
  console.log(`chave ja existe em ${path}`);
} else {
  const { privateKey } = generateKeyPairSync("rsa", { modulusLength: 3072 });
  writeFileSync(path, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o400 });
  chownSync(path, AUTH_UID, AUTH_UID);
  console.log(`chave RSA 3072 gerada em ${path}`);
}
