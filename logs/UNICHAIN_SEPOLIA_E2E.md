# Unichain Sepolia E2E Log

Hook: `0x2d5309d163320a21375347b8bACEf3d7E1130640`

Demo reserve token: `0xaF2CE000BfE8A2fe7a13A023F9F6C04F7a695a30`

## Deployment

1. Deploy demo reserve token: https://sepolia.uniscan.xyz/tx/0xd60e23f1a316fad1cbdeee2944cfdd658ae1844cad7e16a5bca32d23379ce956
2. Mint demo reserve token: https://sepolia.uniscan.xyz/tx/0xe0250c4ee36c09a9300c5952d303162855eb3ac57fa5f2ccfb4e232ff5e06b4b
3. Deploy `TimeWeightedILSmoothingHook`: https://sepolia.uniscan.xyz/tx/0x76928416f35564bb7534197789d727fa1e450002335447e878715250479f4178

## Full Flow

1. Approve hook to pull demo reserve token: https://sepolia.uniscan.xyz/tx/0x5d4de0c2c93d607382956695075e16e726e507d6a40f466770f1c1493593b4af
2. Fund smoothing reserve with 10,000 token0: https://sepolia.uniscan.xyz/tx/0x6ab53a9be710d78d50d8cb503f76a3d01238479b4114bc3b704f2f047ec73721
3. Record LP A historical Tier 1 position: https://sepolia.uniscan.xyz/tx/0x8a45307cef78d4e20ad912ce3deaa82d537f0e5aa0181e6f9061c11d11940192
4. Record LP B historical Tier 3 position: https://sepolia.uniscan.xyz/tx/0xb251526535784f1de2ac21196c7cfbacdfaadab26e473501fc3da59f797cad1c
5. Settle LP A: https://sepolia.uniscan.xyz/tx/0xf73d270982696f6b216dcc5c9c33514340cfb03b3237f079ce615d5b70f6d3db
6. Settle LP B: https://sepolia.uniscan.xyz/tx/0xff1a7683c1751922841c5ae4b38624b8e72e3a4b22da5a379f0c66e1687ae518

## Observed Outputs

Same simulated 2x price move:

| LP | Tier | Total IL | Requested payout | Actual payout |
| --- | ---: | ---: | ---: | ---: |
| LP A | 25% | `57.1` token0 | `14.275` token0 | `14.275` token0 |
| LP B | 75% | `57.1` token0 | `42.825` token0 | `42.825` token0 |

Final reserve balance: `9,942.9` token0.

