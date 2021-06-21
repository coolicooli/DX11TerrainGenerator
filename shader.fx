//--------------------------------------------------------------------------------------
// 
// Copyright (c) Microsoft Corporation. All rights reserved.
//--------------------------------------------------------------------------------------

// the lighting equations in this code have been taken from https://www.3dgep.com/texturing-lighting-directx-11/
// with some modifications by David White

//--------------------------------------------------------------------------------------
// Constant Buffer Variables
//--------------------------------------------------------------------------------------
cbuffer ConstantBuffer : register( b0 )
{
	matrix World;
	matrix View;
	matrix Projection;
	float4 vOutputColor;
}

Texture2D txDiffuseDDirt : register(t0);
Texture2D txDiffuseGrass : register(t1);
Texture2D txDiffuseLDirt : register(t2);
Texture2D txDiffuseSnow : register(t3);
Texture2D txDiffuseStone : register(t4);
Texture2D txDiffuseModel : register(t5);

SamplerState samLinear : register(s0);

#define MAX_LIGHTS 1
// Light types.
#define DIRECTIONAL_LIGHT 0
#define POINT_LIGHT 1
#define SPOT_LIGHT 2

struct _Material
{
	float4  Emissive;       // 16 bytes
							//----------------------------------- (16 byte boundary)
	float4  Ambient;        // 16 bytes
							//------------------------------------(16 byte boundary)
	float4  Diffuse;        // 16 bytes
							//----------------------------------- (16 byte boundary)
	float4  Specular;       // 16 bytes
							//----------------------------------- (16 byte boundary)
	float   SpecularPower;  // 4 bytes
	bool    UseTexture;     // 4 bytes
	float2  Padding;        // 8 bytes
							//----------------------------------- (16 byte boundary)
};  // Total:               // 80 bytes ( 5 * 16 )

cbuffer MaterialProperties : register(b1)
{
	_Material Material;
};

struct Light
{
	float4      Position;               // 16 bytes
										//----------------------------------- (16 byte boundary)
	float4      Direction;              // 16 bytes
										//----------------------------------- (16 byte boundary)
	float4      Color;                  // 16 bytes
										//----------------------------------- (16 byte boundary)
	float       SpotAngle;              // 4 bytes
	float       ConstantAttenuation;    // 4 bytes
	float       LinearAttenuation;      // 4 bytes
	float       QuadraticAttenuation;   // 4 bytes
										//----------------------------------- (16 byte boundary)
	int         LightType;              // 4 bytes
	bool        Enabled;                // 4 bytes
	int2        Padding;                // 8 bytes
										//----------------------------------- (16 byte boundary)
};  // Total:                           // 80 bytes (5 * 16)

cbuffer LightProperties : register(b2)
{
	float4 EyePosition;                 // 16 bytes
										//----------------------------------- (16 byte boundary)
	float4 GlobalAmbient;               // 16 bytes
										//----------------------------------- (16 byte boundary)
	Light Lights[MAX_LIGHTS];           // 80 * 8 = 640 bytes
}; 

//--------------------------------------------------------------------------------------
struct VS_INPUT
{
    float4 Pos : POSITION;
	float3 Norm : NORMAL;
	float2 Tex : TEXCOORD0;
};

struct PS_INPUT
{
    float4 Pos : SV_POSITION;
	float4 worldPos : POSITION;
	float3 Norm : NORMAL;
	float2 Tex : TEXCOORD0;
};

struct HS_IO
{
    float4 Pos : POSITION0;
    float4 worldPos : POSITION1;
    float3 Norm : NORMAL;
    float2 Tex : TEXCOORD0;
};


float4 DoDiffuse(Light light, float3 L, float3 N)
{
	float NdotL = max(0, dot(N, L));
	return light.Color * NdotL;
}

float4 DoSpecular(Light lightObject, float3 vertexToEye, float3 lightDirectionToVertex, float3 Normal)
{
	float4 lightDir = float4(normalize(-lightDirectionToVertex),1);
	vertexToEye = normalize(vertexToEye);

	float lightIntensity = saturate(dot(Normal, lightDir));
	float4 specular = float4(0, 0, 0, 0);
	if (lightIntensity > 0.0f)
	{
		float3  reflection = normalize(2 * lightIntensity * Normal - lightDir);
		specular = pow(saturate(dot(reflection, vertexToEye)), Material.SpecularPower); // 32 = specular power
	}

	return specular;
}

float DoAttenuation(Light light, float d)
{
	return 1.0f / (light.ConstantAttenuation + light.LinearAttenuation * d + light.QuadraticAttenuation * d * d);
}

struct LightingResult
{
	float4 Diffuse;
	float4 Specular;
};

LightingResult DoPointLight(Light light, float3 vertexToEye, float4 vertexPos, float3 N)
{
	LightingResult result;

	float3 LightDirectionToVertex = (vertexPos - light.Position).xyz;
	float distance = length(LightDirectionToVertex);
	LightDirectionToVertex = LightDirectionToVertex  / distance;

	float3 vertexToLight = (light.Position - vertexPos).xyz;
	distance = length(vertexToLight);
	vertexToLight = vertexToLight / distance;

	float attenuation = DoAttenuation(light, distance);
	attenuation = 1;


	result.Diffuse = DoDiffuse(light, vertexToLight, N) * attenuation;
	result.Specular = DoSpecular(light, vertexToEye, LightDirectionToVertex, N) * attenuation;

	return result;
}

LightingResult ComputeLighting(float4 vertexPos, float3 N)
{
	float3 vertexToEye = normalize(EyePosition - vertexPos).xyz;

	LightingResult totalResult = { { 0, 0, 0, 0 },{ 0, 0, 0, 0 } };

	[unroll]
	for (int i = 0; i < MAX_LIGHTS; ++i)
	{
		LightingResult result = { { 0, 0, 0, 0 },{ 0, 0, 0, 0 } };

		if (!Lights[i].Enabled) 
			continue;
		
		result = DoPointLight(Lights[i], vertexToEye, vertexPos, N);
		
		totalResult.Diffuse += result.Diffuse;
		totalResult.Specular += result.Specular;
	}

	totalResult.Diffuse = saturate(totalResult.Diffuse);
	totalResult.Specular = saturate(totalResult.Specular);

	return totalResult;
}

//--------------------------------------------------------------------------------------
// Vertex Shader
//--------------------------------------------------------------------------------------
PS_INPUT VS( VS_INPUT input )
{
    PS_INPUT output = (PS_INPUT)0;
    output.Pos = input.Pos;
    output.worldPos = mul(input.Pos, World);
	
	// multiply the normal by the world transform (to go from model space to world space)
	output.Norm = mul(float4(input.Norm, 1), World).xyz;

	output.Tex = input.Tex;
    
    return output;
}


//--------------------------------------------------------------------------------------
// Pixel Shader
//--------------------------------------------------------------------------------------

float4 PS(PS_INPUT IN) : SV_TARGET
{
	LightingResult lit = ComputeLighting(IN.worldPos, normalize(IN.Norm));

	float4 texColor = { 1, 1, 1, 1 };

	float4 emissive = Material.Emissive;
	float4 ambient = Material.Ambient * GlobalAmbient;
	float4 diffuse = Material.Diffuse * lit.Diffuse;
	float4 specular = Material.Specular * lit.Specular;

	if (Material.UseTexture)
	{
		if(IN.worldPos.y > 18.0)
        {
            texColor = txDiffuseSnow.Sample(samLinear, IN.Tex);
        }
        else if (IN.worldPos.y > 15.0)
        {
            texColor = txDiffuseStone.Sample(samLinear, IN.Tex);
        }
        else if (IN.worldPos.y > 12.0)
        {
            texColor = txDiffuseGrass.Sample(samLinear, IN.Tex);
        }
        else if (IN.worldPos.y > 9.0)
        {
            texColor = txDiffuseDDirt.Sample(samLinear, IN.Tex);
        }
        else
        {
            texColor = txDiffuseLDirt.Sample(samLinear, IN.Tex);
        }
	}
    else
    {
        texColor = txDiffuseModel.Sample(samLinear, IN.Tex);
    }

	float4 finalColor = (emissive + ambient + diffuse + specular) * texColor;

	return finalColor;
}

//--------------------------------------------------------------------------------------
// PSSolid - render a solid color
//--------------------------------------------------------------------------------------
float4 PSSolid(PS_INPUT input) : SV_Target
{
	return vOutputColor;
}

//-----------------------------------------------------------------
// TESSELATION CODE
//----------------------------------------------------------------

//-----------------------------------------------------------------
// HULL SHADER
//----------------------------------------------------------------

/***********************************************
MARKING SCHEME: Use of Tessellation shaders with Level of Detail
DESCRIPTION: The terrain uses tessellation shaders to render at different levels of resolution for viewing parameters. This must be demonstrated with a camera and a visible and effective LOD.
***********************************************/

// Hull Shader Control Point phase
[domain("tri")]
[partitioning("fractional_odd")]
[outputtopology("triangle_cw")]
[outputcontrolpoints(3)]
[patchconstantfunc("PassThroughConstantHS")]
[maxtessfactor(7.0)]

HS_IO HS(InputPatch<HS_IO, 3> ip, uint i : SV_OutputControlPointID, uint PatchID : SV_PrimitiveID)
{
    HS_IO output;
	
    output.Pos = ip[i].Pos;
    output.worldPos = ip[i].worldPos;
    output.Norm = ip[i].Norm;
    output.Tex = ip[i].Tex;
	
    return output;
}

// hull shader patch constant phase
struct HS_CONSTANT_DATA_OUTPUT
{
    float Edges[3] : SV_TessFactor;
    float Inside : SV_InsideTessFactor;
};

HS_CONSTANT_DATA_OUTPUT PassThroughConstantHS(InputPatch<HS_IO, 3> ip, uint PatchID : SV_PrimitiveID)
{
    float tessellationFactor = 5.0;
    HS_CONSTANT_DATA_OUTPUT output;
    output.Edges[0] = tessellationFactor;
    output.Edges[1] = tessellationFactor;
    output.Edges[2] = tessellationFactor;
    output.Inside = tessellationFactor;
	
    return output;
}

//-----------------------------------------------------------------
// DOMAIN SHADER
//----------------------------------------------------------------

[domain("tri")]
PS_INPUT DS(HS_CONSTANT_DATA_OUTPUT input,
	float3 BarycentricCoordinates : SV_DomainLocation,
	const OutputPatch<HS_IO, 3> TrianglePatch) // control points you specified earlier
{
    PS_INPUT output;
	// Interpolate world space position with barycentric coordinates
	// the x,y,z of barycentric = weights, so each .Pos is being multiplied by a weight and added
	// each .Pos is a control point
    float3 vWorldPos = BarycentricCoordinates.x * TrianglePatch[0].Pos + BarycentricCoordinates.y * TrianglePatch[1].Pos + BarycentricCoordinates.z * TrianglePatch[2].Pos;

    output.Pos = float4(vWorldPos.xyz, 1.0);
    output.Tex = BarycentricCoordinates.x * TrianglePatch[0].Tex + BarycentricCoordinates.y * TrianglePatch[1].Tex + BarycentricCoordinates.z * TrianglePatch[2].Tex;
    output.Norm = BarycentricCoordinates.x * TrianglePatch[0].Norm + BarycentricCoordinates.y * TrianglePatch[1].Norm + BarycentricCoordinates.z * TrianglePatch[2].Norm;
    vWorldPos = BarycentricCoordinates.x * TrianglePatch[0].worldPos + BarycentricCoordinates.y * TrianglePatch[1].worldPos + BarycentricCoordinates.z * TrianglePatch[2].worldPos;
	
	// Need to do WVP here not in VS!
    output.Pos = mul(output.Pos, World);
    output.Pos = mul(output.Pos, View);
    output.Pos = mul(output.Pos, Projection);
    output.worldPos = float4(vWorldPos, 1.0);
	
    return output;
}
