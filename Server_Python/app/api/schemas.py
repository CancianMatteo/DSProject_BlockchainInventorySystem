from typing import Any

from pydantic import BaseModel, EmailStr, Field


class LoginRequest(BaseModel):
    email: EmailStr
    pwd: str = Field(min_length=6, max_length=256)


class ForgotPasswordRequest(BaseModel):
    email: EmailStr


class ResetLoginWithOtpRequest(BaseModel):
    email: EmailStr
    otp: str = Field(min_length=4, max_length=16)
    new_pwd: str = Field(min_length=8, max_length=256)


class SignupRequest(BaseModel):
    admin_token: str
    new_name: str = Field(min_length=1, max_length=100)
    new_surname: str = Field(min_length=1, max_length=100)
    new_email: EmailStr
    new_pwd: str | None = Field(default=None, min_length=8, max_length=256)
    new_role: str = Field(default="user")


class AdminActionRequest(BaseModel):
    admin_token: str


class AdminEmailActionRequest(BaseModel):
    admin_token: str
    email: EmailStr


class RemoveUserRequest(BaseModel):
    email: EmailStr
    admin_token: str | None = None
    pwd: str | None = None


class ChangePasswordRequest(BaseModel):
    email: EmailStr
    old_pwd: str = Field(min_length=6, max_length=256)
    new_pwd: str = Field(min_length=8, max_length=256)


class ChangeUserRoleRequest(BaseModel):
    admin_token: str
    target_email: EmailStr
    new_role: str = Field(min_length=4, max_length=16)


class CheckChainSyncRequest(BaseModel):
    client_block_hash: str | None = Field(default=None, min_length=0, max_length=128)


class AddTransactionRequest(BaseModel):
    session_token: str
    transaction: dict[str, Any]


class TransactionStatusRequest(BaseModel):
    session_token: str
    trans_id: str = Field(min_length=1, max_length=128)


class BuildProposalRequest(BaseModel):
    round: int = Field(ge=0)
